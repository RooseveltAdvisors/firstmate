#!/usr/bin/env python3
"""
bin/fm-jev-reorder-guard.py - Host Network TCP Packet Reordering Metric & Out-of-Order Queue Guard (Pattern 188)

Audits kernel TCP packet reordering threshold (tcp_reordering), maximum reordering metric (tcp_max_reordering),
and netstat out-of-order queue counters (TCPOFOQueue, TCPOFODrop, TCPOFOMerge, TCPSACKReorder, TCPTSReorder).
Verifies adaptive TCP reordering detection, ensures out-of-order packet queues remain uncorrupted without drops,
and prevents spurious fast retransmits or throughput collapses across multi-agent multipath and VPN tunnels.
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict


def read_sysctl_int(path: str) -> int:
    if not os.path.exists(path):
        return -1
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception as e:
        print(f"Warning: unable to read {path}: {e}", file=sys.stderr)
        return -1


def parse_netstat(path: str = "/proc/net/netstat") -> Dict[str, int]:
    counters: Dict[str, int] = {}
    if not os.path.exists(path):
        return counters
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
        for i in range(0, len(lines), 2):
            if i + 1 >= len(lines):
                break
            headers = lines[i].split()
            values = lines[i + 1].split()
            if len(headers) == len(values) and headers[0] == values[0]:
                for h, v in zip(headers[1:], values[1:]):
                    try:
                        counters[h] = int(v)
                    except ValueError:
                        pass
    except Exception as e:
        print(f"Warning: unable to parse netstat {path}: {e}", file=sys.stderr)
    return counters


def audit_reordering(
    reordering_file: str = "/proc/sys/net/ipv4/tcp_reordering",
    max_reordering_file: str = "/proc/sys/net/ipv4/tcp_max_reordering",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    reordering = read_sysctl_int(reordering_file)
    max_reordering = read_sysctl_int(max_reordering_file)

    netstat = parse_netstat(netstat_file)

    ofo_queue = netstat.get("TCPOFOQueue", 0)
    ofo_drop = netstat.get("TCPOFODrop", 0)
    ofo_merge = netstat.get("TCPOFOMerge", 0)
    sack_reorder = netstat.get("TCPSACKReorder", 0)
    reno_reorder = netstat.get("TCPRenoReorder", 0)
    ts_reorder = netstat.get("TCPTSReorder", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    if reordering == -1:
        status = "WARNING"
        healthy = False
        issues.append("Unable to read net.ipv4.tcp_reordering sysctl")
    elif reordering < 3:
        status = "WARNING"
        healthy = False
        issues.append(f"TCP reordering threshold is sub-optimal: {reordering} (< 3 causes spurious fast retransmits)")
    elif reordering > 100:
        status = "WARNING"
        healthy = False
        issues.append(f"TCP reordering threshold is excessively high: {reordering} (> 100 delays packet loss detection)")

    if max_reordering == -1:
        status = "WARNING"
        healthy = False
        issues.append("Unable to read net.ipv4.tcp_max_reordering sysctl")
    elif max_reordering < reordering and reordering != -1:
        status = "WARNING"
        healthy = False
        issues.append(f"tcp_max_reordering ({max_reordering}) is less than tcp_reordering ({reordering})")
    elif max_reordering > 1000:
        status = "WARNING"
        healthy = False
        issues.append(f"tcp_max_reordering is excessively high: {max_reordering} (> 1000)")

    if ofo_drop > 100:
        status = "WARNING"
        healthy = False
        issues.append(f"High TCP out-of-order queue packet drops detected: {ofo_drop}")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_reordering": reordering,
        "tcp_max_reordering": max_reordering,
        "ofo_queue": ofo_queue,
        "ofo_drop": ofo_drop,
        "ofo_merge": ofo_merge,
        "sack_reorder": sack_reorder,
        "reno_reorder": reno_reorder,
        "ts_reorder": ts_reorder,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_reordering": reordering,
            "tcp_max_reordering": max_reordering,
        },
        "counters": {
            "TCPOFOQueue": ofo_queue,
            "TCPOFODrop": ofo_drop,
            "TCPOFOMerge": ofo_merge,
            "TCPSACKReorder": sack_reorder,
            "TCPRenoReorder": reno_reorder,
            "TCPTSReorder": ts_reorder,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Packet Reordering Metric & Out-of-Order Queue Guard (Pattern 188)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_reordering()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Packet Reordering Guard (Pattern 188) - Status: {s['status']}")
    print(f"  tcp_reordering:        {s['tcp_reordering']} packets (initial threshold)")
    print(f"  tcp_max_reordering:    {s['tcp_max_reordering']} packets (ceiling)")
    print(f"  Out-of-Order Packets:  {s['ofo_queue']}")
    print(f"  Out-of-Order Drops:    {s['ofo_drop']}")
    print(f"  Out-of-Order Merges:   {s['ofo_merge']}")
    print(f"  SACK Reorder Events:   {s['sack_reorder']}")
    print(f"  TS Reorder Events:     {s['ts_reorder']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
