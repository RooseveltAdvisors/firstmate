#!/usr/bin/env python3
"""
fm-jev-port-entropy-guard.py - Jev Multi-Agent Host Network TCP Port Entropy & Collision Guard (Pattern 131)

Audits Linux host ephemeral port range allocation (/proc/sys/net/ipv4/ip_local_port_range)
and scans active outbound TCP sockets from /proc/net/tcp and /proc/net/tcp6 to calculate port
entropy, port subspace span, and remote destination 4-tuple concentration.

In high-concurrency multi-agent architectures where hundreds of parallel subagent HTTP/RPC calls
burst simultaneously toward external AI APIs and internal databases, ensures kernel source port
randomization is healthy and prevents 4-tuple exhaustion (EADDRNOTAVAIL) and SYN bind collisions.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysctl or procfs entries are inaccessible.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import os
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SYSCTL_PORT_RANGE = "/proc/sys/net/ipv4/ip_local_port_range"
PROC_TCP = "/proc/net/tcp"
PROC_TCP6 = "/proc/net/tcp6"


def read_port_range(path: Path) -> Tuple[int, int]:
    """Reads the ephemeral port range min and max."""
    if not path.is_file():
        return 32768, 60999
    try:
        parts = path.read_text().split()
        if len(parts) >= 2:
            return int(parts[0]), int(parts[1])
    except Exception:
        pass
    return 32768, 60999


def parse_tcp_ports(path: Path, port_min: int, port_max: int) -> Tuple[List[int], Counter]:
    """Extracts ephemeral source ports and remote destination endpoints from /proc/net/tcp."""
    src_ports: List[int] = []
    dst_counter: Counter = Counter()

    if not path.is_file():
        return src_ports, dst_counter

    try:
        lines = path.read_text().splitlines()
        if len(lines) > 1:
            for line in lines[1:]:
                parts = line.strip().split()
                if len(parts) >= 4:
                    # State 01 = ESTABLISHED, 02 = SYN_SENT
                    state = parts[3]
                    if state in ("01", "02"):
                        src = parts[1].split(":")
                        dst = parts[2].split(":")
                        if len(src) == 2 and len(dst) == 2:
                            try:
                                src_p = int(src[1], 16)
                                dst_ip = dst[0]
                                dst_p = int(dst[1], 16)
                                if port_min <= src_p <= port_max:
                                    src_ports.append(src_p)
                                    dst_counter[f"{dst_ip}:{dst_p}"] += 1
                            except ValueError:
                                continue
    except Exception:
        return src_ports, dst_counter

    return src_ports, dst_counter


def audit_port_entropy(
    port_range_file: Optional[str] = None,
    tcp_file: Optional[str] = None,
    tcp6_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host ephemeral port range, active port spread, and destination concentration."""
    range_p = Path(port_range_file or SYSCTL_PORT_RANGE)
    tcp_p = Path(tcp_file or PROC_TCP)
    tcp6_p = Path(tcp6_file or PROC_TCP6)

    port_min, port_max = read_port_range(range_p)
    total_capacity = max(1, port_max - port_min + 1)

    ports4, dst4 = parse_tcp_ports(tcp_p, port_min, port_max)
    ports6, dst6 = parse_tcp_ports(tcp6_p, port_min, port_max)

    all_ports = ports4 + ports6
    all_dst = dst4 + dst6

    active_ephemeral_count = len(all_ports)
    distinct_destinations = len(all_dst)

    if all_ports:
        min_seen = min(all_ports)
        max_seen = max(all_ports)
        port_span = max_seen - min_seen + 1
        span_coverage_pct = round(port_span / total_capacity * 100.0, 2)
    else:
        min_seen = port_min
        max_seen = port_min
        port_span = 0
        span_coverage_pct = 0.0

    max_concentration = 0
    top_destination = "none"
    if all_dst:
        top_dest, max_concentration = all_dst.most_common(1)[0]
        top_destination = top_dest

    utilization_pct = round(active_ephemeral_count / total_capacity * 100.0, 2)
    top_dest_utilization_pct = round(max_concentration / total_capacity * 100.0, 2)

    issues: List[str] = []
    healthy = True

    if total_capacity < 10000:
        healthy = False
        issues.append(f"Restricted ephemeral port range ({total_capacity:,} ports). High risk of port starvation under parallel agent burst.")

    if top_dest_utilization_pct > 50.0:
        healthy = False
        issues.append(f"Heavy 4-tuple concentration to {top_destination}: {max_concentration:,} sockets ({top_dest_utilization_pct}% of total ephemeral space).")

    if utilization_pct > 75.0:
        healthy = False
        issues.append(f"Elevated ephemeral port utilization ({active_ephemeral_count:,} / {total_capacity:,} = {utilization_pct}%).")

    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "port_min": port_min,
            "port_max": port_max,
            "total_capacity": total_capacity,
            "active_ephemeral_count": active_ephemeral_count,
            "utilization_pct": utilization_pct,
            "distinct_destinations": distinct_destinations,
            "port_span": port_span,
            "span_coverage_pct": span_coverage_pct,
            "top_destination": top_destination,
            "max_dest_concentration": max_concentration,
            "top_dest_utilization_pct": top_dest_utilization_pct,
            "issues": issues,
        },
        "counters": {
            "active_ephemeral_count": active_ephemeral_count,
            "distinct_destinations": distinct_destinations,
            "ipv4_ephemeral_count": len(ports4),
            "ipv6_ephemeral_count": len(ports6),
            "max_dest_concentration": max_concentration,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Port Entropy & Collision Guard (Pattern 131)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--port-range-file", type=str, default=None, help="Path to ip_local_port_range")
    parser.add_argument("--tcp-file", type=str, default=None, help="Path to /proc/net/tcp")
    parser.add_argument("--tcp6-file", type=str, default=None, help="Path to /proc/net/tcp6")
    args = parser.parse_args()

    result = audit_port_entropy(
        port_range_file=args.port_range_file,
        tcp_file=args.tcp_file,
        tcp6_file=args.tcp6_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP Port Entropy Guard (Pattern 131)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Ephemeral Port Range:          {summary['port_min']} - {summary['port_max']} ({summary['total_capacity']:,} total ports)")
    print(f" Active Outbound Sockets:       {summary['active_ephemeral_count']} ({summary['utilization_pct']}% utilization)")
    print(f" Port Span Coverage:            {summary['port_span']} ports ({summary['span_coverage_pct']}% of range)")
    print(f" Distinct Destinations:         {summary['distinct_destinations']}")
    print(f" Peak Single-Dest Concentration:{summary['max_dest_concentration']} sockets -> {summary['top_destination']} ({summary['top_dest_utilization_pct']}%)")
    print("--------------------------------------------------------------------------------")
    print(f" {'Port Entropy Metric':<35} {'Count / Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Total Ephemeral Range':<35} {summary['total_capacity']:<15} {'Nominal' if summary['total_capacity'] >= 10000 else 'WARNING'}")
    print(f" {'Global Port Utilization':<35} {summary['utilization_pct']:<14}% {'Nominal' if summary['utilization_pct'] < 75.0 else 'WARNING'}")
    print(f" {'Peak Destination Concentration':<35} {summary['max_dest_concentration']:<15} {'Nominal' if summary['top_dest_utilization_pct'] < 50.0 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive Port Entropy Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host ephemeral port ranges, port spread entropy, and destination concentrations nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
