#!/usr/bin/env python3
"""
fm-jev-keepalive-guard.py - Jev Multi-Agent Host Network TCP Keepalive & Dead Peer Detection Guard (Pattern 101)

Audits Linux host TCP keepalive parameters (/proc/sys/net/ipv4/tcp_keepalive_time, tcp_keepalive_intvl,
tcp_keepalive_probes) and inspects connection timer states from /proc/net/tcp and /proc/net/tcp6.

Calculates dead peer detection latency (idle time + interval * probes) and warns against kernel default
hang windows (7,200s / 2+ hours) that leave abandoned subagent RPC and LLM streaming sockets hanging indefinitely.

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

SYSCTL_KEEPALIVE_TIME = "/proc/sys/net/ipv4/tcp_keepalive_time"
SYSCTL_KEEPALIVE_INTVL = "/proc/sys/net/ipv4/tcp_keepalive_intvl"
SYSCTL_KEEPALIVE_PROBES = "/proc/sys/net/ipv4/tcp_keepalive_probes"
PROC_NET_TCP = "/proc/net/tcp"
PROC_NET_TCP6 = "/proc/net/tcp6"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def parse_tcp_timers(path: Path) -> Tuple[int, int, int]:
    """Parses TCP timer states from /proc/net/tcp or tcp6: returns (keepalive_active, retrans_active, total_sockets)."""
    if not path.is_file():
        return 0, 0, 0

    keepalive_count = 0
    retrans_count = 0
    total_sockets = 0

    try:
        lines = path.read_text().splitlines()
        for line in lines[1:]:
            parts = line.split()
            if len(parts) >= 6:
                total_sockets += 1
                tr_state = parts[5].split(":")[0]
                if tr_state == "02":  # keepalive timer active
                    keepalive_count += 1
                elif tr_state == "01":  # retransmit timer active
                    retrans_count += 1
    except Exception:
        pass

    return keepalive_count, retrans_count, total_sockets


def audit_keepalive(
    keepalive_time_file: Optional[str] = None,
    keepalive_intvl_file: Optional[str] = None,
    keepalive_probes_file: Optional[str] = None,
    tcp_file: Optional[str] = None,
    tcp6_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host TCP keepalive configuration and timer distributions."""
    time_path = Path(keepalive_time_file) if keepalive_time_file else Path(SYSCTL_KEEPALIVE_TIME)
    intvl_path = Path(keepalive_intvl_file) if keepalive_intvl_file else Path(SYSCTL_KEEPALIVE_INTVL)
    probes_path = Path(keepalive_probes_file) if keepalive_probes_file else Path(SYSCTL_KEEPALIVE_PROBES)
    tcp_path = Path(tcp_file) if tcp_file else Path(PROC_NET_TCP)
    tcp6_path = Path(tcp6_file) if tcp6_file else Path(PROC_NET_TCP6)

    ka_time = read_int_file(time_path) or 7200
    ka_intvl = read_int_file(intvl_path) or 75
    ka_probes = read_int_file(probes_path) or 9

    total_dead_peer_latency_sec = ka_time + (ka_intvl * ka_probes)

    ka_v4, retrans_v4, total_v4 = parse_tcp_timers(tcp_path)
    ka_v6, retrans_v6, total_v6 = parse_tcp_timers(tcp6_path)

    total_tcp_sockets = total_v4 + total_v6
    total_keepalive_active = ka_v4 + ka_v6
    total_retrans_active = retrans_v4 + retrans_v6

    issues: List[str] = []

    if ka_time > 1800:
        issues.append(
            f"High tcp_keepalive_time ({ka_time}s > 1,800s): dead peer detection latency is {total_dead_peer_latency_sec}s (~{total_dead_peer_latency_sec / 60:.1f}m)"
        )

    if total_retrans_active > 30:
        issues.append(
            f"Elevated TCP connections in retransmit backoff ({total_retrans_active} sockets): potential unreachable peers"
        )

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_keepalive_time_sec": ka_time,
            "tcp_keepalive_intvl_sec": ka_intvl,
            "tcp_keepalive_probes": ka_probes,
            "total_dead_peer_latency_sec": total_dead_peer_latency_sec,
            "total_tcp_sockets": total_tcp_sockets,
            "keepalive_timer_active": total_keepalive_active,
            "retrans_timer_active": total_retrans_active,
            "issues": issues,
        },
        "details": {
            "ipv4": {"total": total_v4, "keepalive_active": ka_v4, "retrans_active": retrans_v4},
            "ipv6": {"total": total_v6, "keepalive_active": ka_v6, "retrans_active": retrans_v6},
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Keepalive & Dead Peer Detection Guard (Pattern 101)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--time-file", type=str, default=None, help="Path to tcp_keepalive_time")
    parser.add_argument("--intvl-file", type=str, default=None, help="Path to tcp_keepalive_intvl")
    parser.add_argument("--probes-file", type=str, default=None, help="Path to tcp_keepalive_probes")
    parser.add_argument("--tcp-file", type=str, default=None, help="Path to /proc/net/tcp")
    parser.add_argument("--tcp6-file", type=str, default=None, help="Path to /proc/net/tcp6")
    args = parser.parse_args()

    result = audit_keepalive(
        keepalive_time_file=args.time_file,
        keepalive_intvl_file=args.intvl_file,
        keepalive_probes_file=args.probes_file,
        tcp_file=args.tcp_file,
        tcp6_file=args.tcp6_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    details = result["details"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP Keepalive Guard (Pattern 101)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Keepalive Time (Idle):         {summary['tcp_keepalive_time_sec']}s")
    print(f" Keepalive Interval:            {summary['tcp_keepalive_intvl_sec']}s")
    print(f" Keepalive Probes:              {summary['tcp_keepalive_probes']}")
    print(f" Total Dead Peer Latency:       {summary['total_dead_peer_latency_sec']}s (~{summary['total_dead_peer_latency_sec'] / 60:.1f}m)")
    print("--------------------------------------------------------------------------------")
    print(f" {'Socket Category':<30} {'Count':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Total TCP Sockets':<30} {summary['total_tcp_sockets']:<15} Nominal")
    print(f" {'Keepalive Timers Active':<30} {summary['keepalive_timer_active']:<15} Nominal")
    print(f" {'Retransmit Timers Active':<30} {summary['retrans_timer_active']:<15} {'Nominal' if summary['retrans_timer_active'] <= 30 else 'WARNING'}")
    print(f" {'IPv4 Sockets (ka/retrans)':<30} {details['ipv4']['total']} ({details['ipv4']['keepalive_active']}/{details['ipv4']['retrans_active']})")
    print(f" {'IPv6 Sockets (ka/retrans)':<30} {details['ipv6']['total']} ({details['ipv6']['keepalive_active']}/{details['ipv6']['retrans_active']})")

    if summary["issues"]:
        print("\nActive TCP Keepalive / Dead Peer Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll TCP keepalive timeouts, probe counts, and socket timer states nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
