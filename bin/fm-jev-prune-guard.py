#!/usr/bin/env python3
"""
fm-jev-prune-guard.py - Jev Multi-Agent Host Network TCP Receive Queue Pruning & Buffer Collapse Guard (Pattern 138)

Audits Linux TCP receive buffer autotuning policy (/proc/sys/net/ipv4/tcp_moderate_rcvbuf),
receive buffer limits (/proc/sys/net/ipv4/tcp_rmem), and receive buffer pruning / collapse
counters from /proc/net/netstat (PruneCalled, RcvPruned, OfoPruned, TCPRcvCollapsed, TCPMemoryPressures).

In distributed agent environments where processes stream heavy JSON-RPC responses, large git diffs,
and diagnostic bundles, receive buffer exhaustion causes the Linux TCP stack to invoke receive queue
pruning (dropping unread or out-of-order packets) and buffer collapsing (coalescing sk_buffs under CPU penalty).

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
from typing import Any, Dict, List, Optional, Tuple

SYSCTL_MODERATE_RCVBUF = "/proc/sys/net/ipv4/tcp_moderate_rcvbuf"
SYSCTL_RMEM = "/proc/sys/net/ipv4/tcp_rmem"

PROC_NETSTAT = "/proc/net/netstat"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def read_rmem_file(path: Path) -> Tuple[int, int, int]:
    """Reads the 3 rmem values (min, default, max) in bytes."""
    if not path.is_file():
        return (4096, 131072, 33554432)
    try:
        parts = path.read_text().strip().split()
        if len(parts) >= 3:
            return (int(parts[0]), int(parts[1]), int(parts[2]))
    except Exception:
        pass
    return (4096, 131072, 33554432)


def parse_netstat_prune_counters(netstat_path: Path) -> Dict[str, int]:
    """Parses receive prune and memory collapse counters from /proc/net/netstat."""
    counters: Dict[str, int] = {
        "prune_called": 0,
        "rcv_pruned": 0,
        "ofo_pruned": 0,
        "rcv_collapsed": 0,
        "memory_pressures": 0,
        "memory_pressures_chrono": 0,
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

                counters["prune_called"] = header_map.get("PruneCalled", 0)
                counters["rcv_pruned"] = header_map.get("RcvPruned", 0)
                counters["ofo_pruned"] = header_map.get("OfoPruned", 0)
                counters["rcv_collapsed"] = header_map.get("TCPRcvCollapsed", 0)
                counters["memory_pressures"] = header_map.get("TCPMemoryPressures", 0)
                counters["memory_pressures_chrono"] = header_map.get("TCPMemoryPressuresChrono", 0)
                break
    except Exception:
        pass

    return counters


def audit_prune(
    moderate_rcvbuf_file: Optional[str] = None,
    rmem_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TCP receive buffer tuning and pruning counters."""
    mod_path = Path(moderate_rcvbuf_file) if moderate_rcvbuf_file else Path(SYSCTL_MODERATE_RCVBUF)
    rmem_path = Path(rmem_file) if rmem_file else Path(SYSCTL_RMEM)
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)

    moderate_rcvbuf = read_int_file(mod_path)
    if moderate_rcvbuf is None:
        moderate_rcvbuf = 1

    rmem_min, rmem_default, rmem_max = read_rmem_file(rmem_path)
    counters = parse_netstat_prune_counters(netstat_path)

    issues: List[str] = []

    if moderate_rcvbuf == 0:
        issues.append("tcp_moderate_rcvbuf is disabled (0); receive window autotuning is inactive")

    if rmem_max < 4194304:  # Less than 4MB
        issues.append(f"tcp_rmem max ({rmem_max} bytes) is below recommended 4MB floor")

    if counters["memory_pressures"] > 0:
        issues.append(
            f"Host TCP stack experienced {counters['memory_pressures']} global memory pressure episodes"
        )

    if counters["rcv_pruned"] > 50000:
        issues.append(
            f"High receive queue prune events detected ({counters['rcv_pruned']} packets dropped from receive window)"
        )

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "tcp_moderate_rcvbuf": moderate_rcvbuf,
            "tcp_rmem_min_bytes": rmem_min,
            "tcp_rmem_default_bytes": rmem_default,
            "tcp_rmem_max_bytes": rmem_max,
            "tcp_rmem_max_mb": round(rmem_max / (1024 * 1024), 2),
            "issues": issues,
        },
        "counters": counters,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Receive Queue Pruning & Buffer Collapse Guard (Pattern 138)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--moderate-rcvbuf-file", type=str, default=None, help="Path to tcp_moderate_rcvbuf")
    parser.add_argument("--rmem-file", type=str, default=None, help="Path to tcp_rmem")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_prune(
        moderate_rcvbuf_file=args.moderate_rcvbuf_file,
        rmem_file=args.rmem_file,
        netstat_file=args.netstat_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP Receive Prune & Collapse Guard (Pattern 138)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Receive Autotuning:            {'Enabled (1)' if summary['tcp_moderate_rcvbuf'] == 1 else 'Disabled (0)'} (tcp_moderate_rcvbuf)")
    print(f" Receive Buffer Limits (rmem):  Min: {summary['tcp_rmem_min_bytes']}B | Def: {summary['tcp_rmem_default_bytes']}B | Max: {summary['tcp_rmem_max_mb']}MB")
    print(f" Prune Invocations:             {counters['prune_called']:,}")
    print(f" Receive Window Packets Pruned: {counters['rcv_pruned']:,}")
    print(f" Out-of-Order Packets Pruned:   {counters['ofo_pruned']:,}")
    print(f" TCP Receive Buffer Collapses:  {counters['rcv_collapsed']:,}")
    print(f" Global TCP Memory Pressures:   {counters['memory_pressures']:,} ({counters['memory_pressures_chrono']:,} ticks)")
    print("--------------------------------------------------------------------------------")
    print(f" {'Receive Buffer Pruning Metric':<35} {'Count / Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'tcp_moderate_rcvbuf':<35} {summary['tcp_moderate_rcvbuf']:<15} {'Nominal' if summary['tcp_moderate_rcvbuf'] == 1 else 'WARNING'}")
    print(f" {'tcp_rmem_max':<35} {str(summary['tcp_rmem_max_mb']) + ' MB':<15} {'Nominal' if summary['tcp_rmem_max_mb'] >= 4.0 else 'WARNING'}")
    print(f" {'Global Memory Pressures':<35} {counters['memory_pressures']:<15} {'Nominal' if counters['memory_pressures'] == 0 else 'WARNING'}")
    print(f" {'Rcv Window Pruned Packets':<35} {counters['rcv_pruned']:<15} {'Nominal' if counters['rcv_pruned'] <= 50000 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive TCP Receive Queue / Memory Pressure Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP receive buffer autotuning, buffer collapse, and queue prune metrics nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
