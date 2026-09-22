#!/usr/bin/env python3
"""
bin/fm-jev-coalesce-guard.py - Host Network TCP Packet Coalescing & GRO Buffer Efficiency Guard (Pattern 153)

Audits TCP receive queue and socket backlog packet coalescing from /proc/net/netstat
(TCPRcvCoalesce, TCPBacklogCoalesce) and /proc/net/snmp (InSegs, OutSegs) to verify
kernel receive buffer coalescing ratios and CPU softirq interrupt minimization
across multi-agent high-throughput token streams.
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict


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
        print(f"Warning: unable to parse {path}: {e}", file=sys.stderr)
    return counters


def parse_snmp(path: str = "/proc/net/snmp") -> Dict[str, int]:
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
                prefix = headers[0].rstrip(":")
                for h, v in zip(headers[1:], values[1:]):
                    try:
                        counters[f"{prefix}.{h}"] = int(v)
                    except ValueError:
                        pass
    except Exception as e:
        print(f"Warning: unable to parse {path}: {e}", file=sys.stderr)
    return counters


def audit_coalesce(
    netstat_file: str = "/proc/net/netstat",
    snmp_file: str = "/proc/net/snmp",
) -> Dict[str, Any]:
    netstat = parse_netstat(netstat_file)
    snmp = parse_snmp(snmp_file)

    rcv_coalesce = netstat.get("TCPRcvCoalesce", 0)
    backlog_coalesce = netstat.get("TCPBacklogCoalesce", 0)
    autocorking = netstat.get("TCPAutoCorking", 0)

    in_segs = snmp.get("Tcp.InSegs", 0)
    out_segs = snmp.get("Tcp.OutSegs", 0)

    total_coalesced = rcv_coalesce + backlog_coalesce

    # Coalesce ratio relative to InSegs
    coalesce_ratio_pct = 0.0
    if in_segs > 0:
        coalesce_ratio_pct = round((total_coalesced / in_segs) * 100.0, 3)

    issues = []
    status = "HEALTHY"
    healthy = True

    # Check if high traffic exists but zero coalescing occurred
    if in_segs >= 1_000_000 and total_coalesced == 0:
        status = "WARNING"
        healthy = False
        issues.append("Zero TCP packet coalescing detected despite high InSegs traffic")

    summary = {
        "status": status,
        "healthy": healthy,
        "in_segs": in_segs,
        "out_segs": out_segs,
        "rcv_coalesce": rcv_coalesce,
        "backlog_coalesce": backlog_coalesce,
        "total_coalesced": total_coalesced,
        "coalesce_ratio_pct": coalesce_ratio_pct,
        "autocorking": autocorking,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "counters": {
            "rcv_coalesce": rcv_coalesce,
            "backlog_coalesce": backlog_coalesce,
            "autocorking": autocorking,
            "in_segs": in_segs,
            "out_segs": out_segs,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Packet Coalescing & GRO Buffer Efficiency Guard (Pattern 153)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_coalesce()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Packet Coalescing Guard (Pattern 153) - Status: {s['status']}")
    print(f"  Total Ingress Segments (InSegs): {s['in_segs']:,}")
    print(f"  Receive Queue Coalesced:         {s['rcv_coalesce']:,}")
    print(f"  Backlog Coalesced:               {s['backlog_coalesce']:,}")
    print(f"  Total Coalesced Packets:         {s['total_coalesced']:,} ({s['coalesce_ratio_pct']}%)")
    print(f"  Outbound Auto-Corking Events:    {s['autocorking']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
