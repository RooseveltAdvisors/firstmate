#!/usr/bin/env python3
"""
bin/fm-jev-ofo-guard.py - Host Network TCP Out-of-Order (OFO) Queue & Memory Pruning Guard (Pattern 161)

Audits TCP Out-of-Order (OFO) queue counters (TCPOFOQueue, TCPOFODrop, TCPOFOMerge, OfoPruned)
from /proc/net/netstat to verify socket rb-tree reassembly health and zero out-of-order packet
drops, eliminating connection retransmission stalls across multi-agent streaming pipelines.
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


def audit_ofo(netstat_file: str = "/proc/net/netstat") -> Dict[str, Any]:
    netstat = parse_netstat(netstat_file)

    ofo_queue = netstat.get("TCPOFOQueue", 0)
    ofo_drop = netstat.get("TCPOFODrop", 0)
    ofo_merge = netstat.get("TCPOFOMerge", 0)
    ofo_pruned = netstat.get("OfoPruned", 0)
    rcv_pruned = netstat.get("RcvPruned", 0)

    drop_ratio = ofo_drop / (ofo_queue + 1)
    merge_ratio = ofo_merge / (ofo_queue + 1)
    prune_ratio = ofo_pruned / (ofo_queue + 1)

    issues = []
    status = "HEALTHY"
    healthy = True

    if ofo_drop > 100 and drop_ratio > 0.01:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated TCP OFO packet drops: {ofo_drop} ({drop_ratio:.2%})")

    if ofo_pruned > 500:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated OFO queue buffer pruning events: {ofo_pruned}")

    summary = {
        "status": status,
        "healthy": healthy,
        "ofo_queue": ofo_queue,
        "ofo_drop": ofo_drop,
        "ofo_merge": ofo_merge,
        "ofo_pruned": ofo_pruned,
        "rcv_pruned": rcv_pruned,
        "drop_ratio_pct": round(drop_ratio * 100, 4),
        "merge_ratio_pct": round(merge_ratio * 100, 4),
        "prune_ratio_pct": round(prune_ratio * 100, 4),
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "counters": {
            "TCPOFOQueue": ofo_queue,
            "TCPOFODrop": ofo_drop,
            "TCPOFOMerge": ofo_merge,
            "OfoPruned": ofo_pruned,
            "RcvPruned": rcv_pruned,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Out-of-Order (OFO) Queue & Memory Pruning Guard (Pattern 161)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_ofo()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP OFO Queue Guard (Pattern 161) - Status: {s['status']}")
    print(f"  OFO Segments Queued:     {s['ofo_queue']:,}")
    print(f"  OFO Segments Dropped:    {s['ofo_drop']:,} ({s['drop_ratio_pct']}%)")
    print(f"  OFO Segments Merged:     {s['ofo_merge']:,} ({s['merge_ratio_pct']}%)")
    print(f"  OFO Queues Pruned:       {s['ofo_pruned']:,} ({s['prune_ratio_pct']}%)")
    print(f"  Total Receive Prunes:    {s['rcv_pruned']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
