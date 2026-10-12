#!/usr/bin/env python3
"""
fm-jev-tw-guard.py - Jev Multi-Agent Host Network TCP Time-Wait & Socket Port Range Guard (Pattern 97)

Audits Linux host TCP TIME_WAIT sockets, orphan socket counts, ephemeral port range allocation, and timewait bucket
limits from /proc/net/sockstat, /proc/sys/net/ipv4/ip_local_port_range, /proc/sys/net/ipv4/tcp_tw_reuse,
/proc/sys/net/ipv4/tcp_max_tw_buckets, and /proc/sys/net/ipv4/tcp_fin_timeout.

Detects ephemeral port exhaustion (EADDRNOTAVAIL) and memory pressure from orphan/timewait socket accumulation
during intensive multi-agent HTTP/RPC burst traffic.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when /proc files are missing or restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

PROC_SOCKSTAT = "/proc/net/sockstat"
SYSCTL_PORT_RANGE = "/proc/sys/net/ipv4/ip_local_port_range"
SYSCTL_TW_REUSE = "/proc/sys/net/ipv4/tcp_tw_reuse"
SYSCTL_MAX_TW_BUCKETS = "/proc/sys/net/ipv4/tcp_max_tw_buckets"
SYSCTL_FIN_TIMEOUT = "/proc/sys/net/ipv4/tcp_fin_timeout"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def parse_port_range(path: Path) -> Tuple[int, int, int]:
    """Reads start and end ephemeral ports from ip_local_port_range."""
    if not path.is_file():
        return 32768, 60999, 28232
    try:
        parts = path.read_text().strip().split()
        if len(parts) >= 2:
            start_p = int(parts[0])
            end_p = int(parts[1])
            total_p = max(0, end_p - start_p + 1)
            return start_p, end_p, total_p
    except Exception:
        pass
    return 32768, 60999, 28232


def parse_sockstat(path: Path) -> Dict[str, int]:
    """Parses socket counts from /proc/net/sockstat."""
    stats = {
        "sockets_used": 0,
        "tcp_inuse": 0,
        "tcp_orphan": 0,
        "tcp_tw": 0,
        "tcp_alloc": 0,
        "tcp_mem": 0,
    }
    if not path.is_file():
        return stats

    try:
        for line in path.read_text().splitlines():
            line_str = line.strip()
            if line_str.startswith("sockets:"):
                m = re.search(r"used\s+(\d+)", line_str)
                if m:
                    stats["sockets_used"] = int(m.group(1))
            elif line_str.startswith("TCP:"):
                inuse_m = re.search(r"inuse\s+(\d+)", line_str)
                orphan_m = re.search(r"orphan\s+(\d+)", line_str)
                tw_m = re.search(r"tw\s+(\d+)", line_str)
                alloc_m = re.search(r"alloc\s+(\d+)", line_str)
                mem_m = re.search(r"mem\s+(\d+)", line_str)
                if inuse_m:
                    stats["tcp_inuse"] = int(inuse_m.group(1))
                if orphan_m:
                    stats["tcp_orphan"] = int(orphan_m.group(1))
                if tw_m:
                    stats["tcp_tw"] = int(tw_m.group(1))
                if alloc_m:
                    stats["tcp_alloc"] = int(alloc_m.group(1))
                if mem_m:
                    stats["tcp_mem"] = int(mem_m.group(1))
    except Exception:
        pass

    return stats


def audit_tw_sockets(
    sockstat_file: Optional[str] = None,
    port_range_file: Optional[str] = None,
    tw_reuse_file: Optional[str] = None,
    max_tw_buckets_file: Optional[str] = None,
    fin_timeout_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TIME_WAIT sockets against ephemeral port range and system limits."""
    sockstat_path = Path(sockstat_file) if sockstat_file else Path(PROC_SOCKSTAT)
    port_range_path = Path(port_range_file) if port_range_file else Path(SYSCTL_PORT_RANGE)
    tw_reuse_path = Path(tw_reuse_file) if tw_reuse_file else Path(SYSCTL_TW_REUSE)
    max_tw_buckets_path = Path(max_tw_buckets_file) if max_tw_buckets_file else Path(SYSCTL_MAX_TW_BUCKETS)
    fin_timeout_path = Path(fin_timeout_file) if fin_timeout_file else Path(SYSCTL_FIN_TIMEOUT)

    stats = parse_sockstat(sockstat_path)
    start_p, end_p, total_ports = parse_port_range(port_range_path)
    tw_reuse = read_int_file(tw_reuse_path)
    max_tw_buckets = read_int_file(max_tw_buckets_path) or 262144
    fin_timeout = read_int_file(fin_timeout_path) or 60

    tw_sockets = stats["tcp_tw"]
    orphan_sockets = stats["tcp_orphan"]

    # Percentages
    tw_port_pct = (tw_sockets / total_ports * 100.0) if total_ports > 0 else 0.0
    tw_bucket_pct = (tw_sockets / max_tw_buckets * 100.0) if max_tw_buckets > 0 else 0.0

    issues: List[str] = []

    if total_ports < 10000:
        issues.append(f"Restricted ephemeral port range ({total_ports} < 10,000): risk of port exhaustion under high concurrency")

    if tw_port_pct > 70.0:
        issues.append(f"High TIME_WAIT saturation ({tw_port_pct:.1f}% of ephemeral ports): risk of EADDRNOTAVAIL socket errors")

    if tw_bucket_pct > 80.0:
        issues.append(f"High TIME_WAIT bucket utilization ({tw_bucket_pct:.1f}% of {max_tw_buckets}): risk of bucket overflow")

    if orphan_sockets > 200:
        issues.append(f"Elevated orphan TCP sockets ({orphan_sockets} > 200): sockets unattached to user descriptors")

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "ephemeral_port_start": start_p,
            "ephemeral_port_end": end_p,
            "ephemeral_ports_total": total_ports,
            "tw_sockets": tw_sockets,
            "tw_port_utilization_pct": round(tw_port_pct, 2),
            "tw_bucket_utilization_pct": round(tw_bucket_pct, 2),
            "max_tw_buckets": max_tw_buckets,
            "tcp_tw_reuse": tw_reuse,
            "tcp_fin_timeout": fin_timeout,
            "issues": issues,
        },
        "sockets": stats,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Time-Wait & Ephemeral Port Range Guard (Pattern 97)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--sockstat-file", type=str, default=None, help="Path to /proc/net/sockstat")
    parser.add_argument("--port-range-file", type=str, default=None, help="Path to ip_local_port_range")
    parser.add_argument("--tw-reuse-file", type=str, default=None, help="Path to tcp_tw_reuse")
    parser.add_argument("--max-tw-buckets-file", type=str, default=None, help="Path to tcp_max_tw_buckets")
    parser.add_argument("--fin-timeout-file", type=str, default=None, help="Path to tcp_fin_timeout")
    args = parser.parse_args()

    result = audit_tw_sockets(
        sockstat_file=args.sockstat_file,
        port_range_file=args.port_range_file,
        tw_reuse_file=args.tw_reuse_file,
        max_tw_buckets_file=args.max_tw_buckets_file,
        fin_timeout_file=args.fin_timeout_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    sockets = result["sockets"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    tw_reuse_str = {0: "Disabled (0)", 1: "Enabled (1)", 2: "Enabled for Loopback (2)"}.get(
        summary["tcp_tw_reuse"], str(summary["tcp_tw_reuse"])
    )

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP Time-Wait & Ephemeral Port Range Guard (Pattern 97)")
    print("================================================================================")
    print(f" Timestamp:                 {result['timestamp']}")
    print(f" Status:                    {status_color}{summary['status']}{reset_color}")
    print(f" Ephemeral Port Range:      {summary['ephemeral_port_start']} - {summary['ephemeral_port_end']} ({summary['ephemeral_ports_total']} ports)")
    print(f" TCP TW Reuse:              {tw_reuse_str}")
    print(f" TCP Fin Timeout:           {summary['tcp_fin_timeout']}s")
    print(f" Max TW Buckets:            {summary['max_tw_buckets']}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Metric':<30} {'Count':<15} {'Utilization / Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Total Sockets Used':<30} {sockets['sockets_used']:<15} Nominal")
    print(f" {'TCP Sockets In-Use':<30} {sockets['tcp_inuse']:<15} Nominal")
    print(f" {'TCP Sockets Allocated':<30} {sockets['tcp_alloc']:<15} Nominal")
    print(f" {'TCP Orphan Sockets':<30} {sockets['tcp_orphan']:<15} {'Nominal' if sockets['tcp_orphan'] <= 200 else 'WARNING'}")
    print(f" {'TCP TIME_WAIT Sockets':<30} {summary['tw_sockets']:<15} {summary['tw_port_utilization_pct']}% of ports ({summary['tw_bucket_utilization_pct']}% of buckets)")

    if summary["issues"]:
        print("\nActive TIME_WAIT / Port Range Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll TCP TIME_WAIT sockets, orphan socket levels, and ephemeral port capacities nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
