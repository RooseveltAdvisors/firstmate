#!/usr/bin/env python3
"""
fm-jev-zerowin-guard.py - Jev Multi-Agent Host Network TCP Zero-Window Probing & Receiver Buffer Starvation Guard (Pattern 147)

Audits Linux TCP zero-window probe activity, buffer collapse, and receiver window starvation from /proc/net/netstat and sysctl:
  - TCPWinProbe (Window probes sent to probe receiver zero window state)
  - TCPZeroWindowDrop (Packets dropped because receive window remained at zero)
  - TCPRcvCollapsed (Packets coalesced/collapsed into larger skb buffers under memory pressure)
  - TCPMemoryPressures (Subsystem events where TCP entered memory pressure state)
  - TCPPruneDrop (Packets dropped during receive queue pruning)
  - /proc/sys/net/ipv4/tcp_moderate_rcvbuf (TCP receive buffer auto-tuning)
  - /proc/sys/net/ipv4/tcp_rmem (Receive buffer min/default/max limits)

In multi-agent streaming architectures (e.g. LLM streaming token responses or high-frequency IPC),
receiver window starvation occurs when consuming processes fail to drain sockets fast enough,
forcing senders into zero-window probe backoff loops and freezing inference pipelines.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysctl or procfs entries are inaccessible.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

PROC_NETSTAT = "/proc/net/netstat"
SYSCTL_MODERATE_RCVBUF = "/proc/sys/net/ipv4/tcp_moderate_rcvbuf"
SYSCTL_RMEM = "/proc/sys/net/ipv4/tcp_rmem"


def read_file_strip(path: Path, default: str = "") -> str:
    """Reads a sysctl file safely."""
    if not path.is_file():
        return default
    try:
        return path.read_text().strip()
    except Exception:
        return default


def parse_zerowin_counters(netstat_path: Path) -> Dict[str, int]:
    """Parses zero-window and buffer collapse counters from /proc/net/netstat."""
    counters: Dict[str, int] = {
        "win_probe": 0,
        "zero_win_drop": 0,
        "rcv_collapsed": 0,
        "mem_pressures": 0,
        "prune_drop": 0,
        "backlog_drop": 0,
    }

    if not netstat_path.is_file():
        return counters

    try:
        lines = netstat_path.read_text().splitlines()
        for i in range(0, len(lines) - 1, 2):
            header_line = lines[i].strip()
            data_line = lines[i + 1].strip()
            if header_line.startswith("TcpExt:") and data_line.startswith("TcpExt:"):
                headers = header_line.split()[1:]
                values = data_line.split()[1:]
                header_map = {h: int(v) for h, v in zip(headers, values) if v.isdigit()}

                counters["win_probe"] = header_map.get("TCPWinProbe", 0)
                counters["zero_win_drop"] = header_map.get("TCPZeroWindowDrop", 0)
                counters["rcv_collapsed"] = header_map.get("TCPRcvCollapsed", 0)
                counters["mem_pressures"] = header_map.get("TCPMemoryPressures", 0)
                counters["prune_drop"] = header_map.get("TCPPruneDrop", 0)
                counters["backlog_drop"] = header_map.get("TCPBacklogDrop", 0)
                break
    except Exception:
        pass

    return counters


def audit_zerowin(
    netstat_file: Optional[str] = None,
    moderate_rcvbuf_file: Optional[str] = None,
    rmem_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TCP zero-window probe activity and receiver buffer health."""
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)
    mod_path = Path(moderate_rcvbuf_file) if moderate_rcvbuf_file else Path(SYSCTL_MODERATE_RCVBUF)
    rmem_path = Path(rmem_file) if rmem_file else Path(SYSCTL_RMEM)

    mod_rcvbuf_str = read_file_strip(mod_path, "1")
    mod_rcvbuf = int(mod_rcvbuf_str) if mod_rcvbuf_str.isdigit() else 1

    rmem_str = read_file_strip(rmem_path, "4096 131072 6291456")
    rmem_parts = rmem_str.split()
    rmem_max = int(rmem_parts[2]) if len(rmem_parts) >= 3 and rmem_parts[2].isdigit() else 6291456

    counters = parse_zerowin_counters(netstat_path)
    win_probe = counters["win_probe"]
    zero_win_drop = counters["zero_win_drop"]
    rcv_collapsed = counters["rcv_collapsed"]
    mem_pressures = counters["mem_pressures"]
    prune_drop = counters["prune_drop"]

    issues: List[str] = []

    # 1. Zero window packet drops > 0
    if zero_win_drop > 0:
        issues.append(f"Zero-window packet drops detected ({zero_win_drop:,} packets dropped)")

    # 2. Memory pressures > 0
    if mem_pressures > 0:
        issues.append(f"TCP subsystem entered memory pressure ({mem_pressures:,} pressure events)")

    # 3. Prune drops > 0
    if prune_drop > 0:
        issues.append(f"Receive buffer prune packet drops detected ({prune_drop:,} drops)")

    # 4. Moderate receive buffer disabled (0)
    if mod_rcvbuf == 0:
        issues.append("tcp_moderate_rcvbuf is disabled; automatic receive buffer tuning inactive")

    # 5. Rmem max under-provisioned (< 2MB)
    if rmem_max < 2 * 1024 * 1024:
        issues.append(f"tcp_rmem max buffer is low ({rmem_max} bytes < 2MB)")

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "tcp_moderate_rcvbuf": mod_rcvbuf,
            "tcp_rmem_max_bytes": rmem_max,
            "win_probe": win_probe,
            "zero_win_drop": zero_win_drop,
            "rcv_collapsed": rcv_collapsed,
            "mem_pressures": mem_pressures,
            "prune_drop": prune_drop,
            "issues": issues,
        },
        "counters": counters,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Zero-Window Probing & Receiver Buffer Starvation Guard (Pattern 147)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    parser.add_argument("--moderate-rcvbuf-file", type=str, default=None, help="Path to tcp_moderate_rcvbuf")
    parser.add_argument("--rmem-file", type=str, default=None, help="Path to tcp_rmem")
    args = parser.parse_args()

    result = audit_zerowin(
        netstat_file=args.netstat_file,
        moderate_rcvbuf_file=args.moderate_rcvbuf_file,
        rmem_file=args.rmem_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP Zero-Window & Buffer Starvation Guard (Pattern 147)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" tcp_moderate_rcvbuf:           {summary['tcp_moderate_rcvbuf']} (1 = auto-tuning enabled)")
    print(f" tcp_rmem Max Buffer:           {summary['tcp_rmem_max_bytes']:,} bytes ({summary['tcp_rmem_max_bytes'] / (1024*1024):.1f} MiB)")
    print(f" TCP Window Probes Sent:        {summary['win_probe']:,}")
    print(f" TCP Zero-Window Drops:         {summary['zero_win_drop']:,}")
    print(f" TCP Receive Buffer Collapses:  {summary['rcv_collapsed']:,}")
    print(f" TCP Subsystem Memory Pressure: {summary['mem_pressures']:,}")
    print(f" TCP Prune Drops:               {summary['prune_drop']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Zero-Window / Buffer Metric':<35} {'Count / Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Receive Buffer Auto-Tuning':<35} {summary['tcp_moderate_rcvbuf']:<15} {'Nominal' if summary['tcp_moderate_rcvbuf'] == 1 else 'WARNING'}")
    print(f" {'Zero Window Drops':<35} {summary['zero_win_drop']:<15} {'Nominal' if summary['zero_win_drop'] == 0 else 'CRITICAL'}")
    print(f" {'Memory Pressure Events':<35} {summary['mem_pressures']:<15} {'Nominal' if summary['mem_pressures'] == 0 else 'CRITICAL'}")
    print(f" {'Receive Queue Prune Drops':<35} {summary['prune_drop']:<15} {'Nominal' if summary['prune_drop'] == 0 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive TCP Zero-Window / Buffer Starvation Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP zero-window probe activity, receive buffer sizing, and memory pressures nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
