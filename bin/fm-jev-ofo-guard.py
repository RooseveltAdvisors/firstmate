#!/usr/bin/env python3
"""
fm-jev-ofo-guard.py - Jev Multi-Agent Host Network TCP Out-of-Order Queue & Memory Collapse Guard (Pattern 119)

Audits Linux TCP out-of-order (OFO) segment handling, socket buffer collapse operations, and socket backlog drops from
/proc/sys/net/ipv4/tcp_rmem, /proc/sys/net/ipv4/tcp_retrans_collapse, and /proc/net/netstat
(TcpExt: TCPOFOQueue, TCPOFODrop, TCPOFOMerge, TCPRcvCollapsed, TCPRcvCoalesce, TCPBacklogCoalesce,
TCPBacklogDrop, TCPMemoryPressures).

Detects socket buffer memory exhaustion, high-overhead skb restructuring (tcp_collapse), packet loss from
OFO queue overflow during multi-agent concurrent Git pack fetches, LLM streams, and JSON-RPC bursts.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysfs/procfs files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SYSCTL_RMEM = "/proc/sys/net/ipv4/tcp_rmem"
SYSCTL_RETRANS_COLLAPSE = "/proc/sys/net/ipv4/tcp_retrans_collapse"
PROC_NETSTAT = "/proc/net/netstat"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def read_rmem_limits(path: Path) -> Tuple[int, int, int]:
    """Reads min, default, max values from tcp_rmem."""
    if not path.is_file():
        return 4096, 131072, 33554432
    try:
        parts = [int(x) for x in path.read_text().split()]
        if len(parts) >= 3:
            return parts[0], parts[1], parts[2]
        elif len(parts) == 1:
            return parts[0], parts[0], parts[0]
    except Exception:
        pass
    return 4096, 131072, 33554432


def parse_tcpext_netstat(path: Path) -> Dict[str, int]:
    """Parses TcpExt key-value metrics from /proc/net/netstat."""
    if not path.is_file():
        return {}

    metrics: Dict[str, int] = {}
    try:
        lines = path.read_text().splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("TcpExt:") and lines[i + 1].startswith("TcpExt:"):
                keys = lines[i].split()[1:]
                vals_raw = lines[i + 1].split()[1:]
                for k, v in zip(keys, vals_raw):
                    try:
                        metrics[k] = int(v)
                    except ValueError:
                        continue
                break
    except Exception:
        return {}

    return metrics


def audit_ofo(
    rmem_file: Optional[str] = None,
    retrans_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host TCP Out-of-Order Queue & Memory Collapse status."""
    rmem_p = Path(rmem_file or SYSCTL_RMEM)
    retrans_p = Path(retrans_file or SYSCTL_RETRANS_COLLAPSE)
    netstat_p = Path(netstat_file or PROC_NETSTAT)

    rmem_min, rmem_default, rmem_max = read_rmem_limits(rmem_p)
    retrans_collapse = read_int_file(retrans_p)
    if retrans_collapse is None:
        retrans_collapse = 1

    tcpext = parse_tcpext_netstat(netstat_p)

    ofo_queue = tcpext.get("TCPOFOQueue", 0)
    ofo_drop = tcpext.get("TCPOFODrop", 0)
    ofo_merge = tcpext.get("TCPOFOMerge", 0)
    rcv_collapsed = tcpext.get("TCPRcvCollapsed", 0)
    rcv_coalesce = tcpext.get("TCPRcvCoalesce", 0)
    backlog_coalesce = tcpext.get("TCPBacklogCoalesce", 0)
    backlog_drop = tcpext.get("TCPBacklogDrop", 0)
    memory_pressures = tcpext.get("TCPMemoryPressures", 0)

    issues: List[str] = []
    healthy = True

    if retrans_collapse == 0:
        healthy = False
        issues.append("tcp_retrans_collapse is disabled (0). TCP cannot merge adjacent retransmissions.")

    if rmem_max < 16777216:  # 16 MB
        healthy = False
        issues.append(f"tcp_rmem max limit is low ({rmem_max} < 16MB). Memory pressure may force receive queue collapse.")

    if ofo_drop > 100:
        healthy = False
        issues.append(f"Elevated out-of-order packet drops ({ofo_drop:,} drops). Packet reordering is overflowing socket receive buffers.")

    if backlog_drop > 0:
        healthy = False
        issues.append(f"TCP socket backlog drops detected ({backlog_drop:,} drops). Application process not draining receive socket fast enough.")

    if memory_pressures > 0:
        healthy = False
        issues.append(f"TCP socket memory pressure events detected ({memory_pressures:,} occurrences). Global socket memory limits exceeded.")

    if rcv_collapsed > 100000:
        healthy = False
        issues.append(f"High TCP receive buffer collapse operations ({rcv_collapsed:,} collapses). High CPU overhead from skb restructuring.")

    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "tcp_rmem_min": rmem_min,
            "tcp_rmem_default": rmem_default,
            "tcp_rmem_max": rmem_max,
            "tcp_retrans_collapse": retrans_collapse,
            "ofo_queue": ofo_queue,
            "ofo_drop": ofo_drop,
            "ofo_merge": ofo_merge,
            "rcv_collapsed": rcv_collapsed,
            "rcv_coalesce": rcv_coalesce,
            "backlog_coalesce": backlog_coalesce,
            "backlog_drop": backlog_drop,
            "memory_pressures": memory_pressures,
            "issues": issues,
        },
        "counters": {
            "ofo_queue": ofo_queue,
            "ofo_drop": ofo_drop,
            "ofo_merge": ofo_merge,
            "rcv_collapsed": rcv_collapsed,
            "rcv_coalesce": rcv_coalesce,
            "backlog_coalesce": backlog_coalesce,
            "backlog_drop": backlog_drop,
            "memory_pressures": memory_pressures,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Out-of-Order Queue & Memory Collapse Guard (Pattern 119)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--rmem-file", type=str, default=None, help="Path to tcp_rmem")
    parser.add_argument("--retrans-file", type=str, default=None, help="Path to tcp_retrans_collapse")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_ofo(
        rmem_file=args.rmem_file,
        retrans_file=args.retrans_file,
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
    print(" Jev Multi-Agent Host Network TCP Out-of-Order Queue & Memory Collapse Guard (Pattern 119)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Retransmit Collapse:           {summary['tcp_retrans_collapse']} ({'Enabled' if summary['tcp_retrans_collapse'] == 1 else 'Disabled'})")
    print(f" TCP RCV Buffer Limits:         min={summary['tcp_rmem_min']:,} def={summary['tcp_rmem_default']:,} max={summary['tcp_rmem_max']:,} B")
    print(f" Out-of-Order Queue Packets:    {summary['ofo_queue']:,}")
    print(f" Out-of-Order Drops:            {summary['ofo_drop']:,}")
    print(f" Out-of-Order Merges:           {summary['ofo_merge']:,}")
    print(f" Receive Buffer Collapses:      {summary['rcv_collapsed']:,}")
    print(f" Receive Queue Coalescing:      {summary['rcv_coalesce']:,}")
    print(f" Backlog Queue Coalescing:      {summary['backlog_coalesce']:,}")
    print(f" Socket Backlog Drops:          {summary['backlog_drop']:,}")
    print(f" TCP Memory Pressures:          {summary['memory_pressures']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Queue / Collapse Metric':<35} {'Count':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Out-of-Order Packets Queued':<35} {counters['ofo_queue']:<15} Nominal")
    print(f" {'Out-of-Order Packets Dropped':<35} {counters['ofo_drop']:<15} {'Nominal' if counters['ofo_drop'] <= 100 else 'WARNING'}")
    print(f" {'Out-of-Order Packets Merged':<35} {counters['ofo_merge']:<15} Nominal")
    print(f" {'Receive Buffer Collapses':<35} {counters['rcv_collapsed']:<15} {'Nominal' if counters['rcv_collapsed'] <= 100000 else 'WARNING'}")
    print(f" {'Receive Queue Coalesced':<35} {counters['rcv_coalesce']:<15} Nominal")
    print(f" {'Backlog Queue Coalesced':<35} {counters['backlog_coalesce']:<15} Nominal")
    print(f" {'Socket Backlog Drops':<35} {counters['backlog_drop']:<15} {'Nominal' if counters['backlog_drop'] == 0 else 'WARNING'}")
    print(f" {'Memory Pressure Events':<35} {counters['memory_pressures']:<15} {'Nominal' if counters['memory_pressures'] == 0 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive TCP Out-of-Order & Memory Collapse Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP out-of-order queue and socket buffer collapse parameters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
