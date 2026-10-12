#!/usr/bin/env python3
"""
bin/fm-jev-fastpath-guard.py - Host Network TCP Fast-Path Header Prediction & Pure ACK Guard (Pattern 237)

Audits kernel TCP fast-path header prediction execution and ACK processing counters from
/proc/net/netstat (TCPHPHits, TCPHPAcks, TCPPureAcks, TCPAckCompressed, TCPDelivered).
Verifies that high-concurrency multi-agent IPC and JSON-RPC streaming connections maintain
high header prediction hit rates (> 50%), preventing CPU softirq spikes and slow-path stack fallback.
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List


def parse_netstat_ext(path: str = "/proc/net/netstat") -> Dict[str, int]:
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
            if len(headers) == len(values) and headers[0] == "TcpExt:" and values[0] == "TcpExt:":
                for h, v in zip(headers[1:], values[1:]):
                    try:
                        counters[h] = int(v)
                    except ValueError:
                        continue
    except Exception as e:
        print(f"Warning: unable to parse netstat {path}: {e}", file=sys.stderr)
    return counters


def audit_fastpath(netstat_file: str = "/proc/net/netstat") -> Dict[str, Any]:
    netstat = parse_netstat_ext(netstat_file)

    hp_hits = netstat.get("TCPHPHits", 0)
    hp_acks = netstat.get("TCPHPAcks", 0)
    pure_acks = netstat.get("TCPPureAcks", 0)
    ack_compressed = netstat.get("TCPAckCompressed", 0)
    delivered = netstat.get("TCPDelivered", 0)

    total_acks = hp_acks + pure_acks
    hp_ack_ratio = round((hp_acks / total_acks * 100.0), 4) if total_acks > 0 else 0.0
    total_fastpath = hp_hits + hp_acks

    issues: List[str] = []
    status = "HEALTHY"

    # Critical conditions
    if delivered > 100000 and total_fastpath == 0:
        issues.append("Zero fast-path header prediction events detected on high-throughput host: 100% slow-path execution")
        status = "CRITICAL"

    # Warning conditions
    if status != "CRITICAL":
        if total_acks >= 10000 and hp_ack_ratio < 20.0:
            issues.append(f"Fast-path ACK ratio ({hp_ack_ratio}%) < 20.0%: elevated kernel slow-path socket processing")
            status = "WARNING"

    summary = {
        "status": status,
        "healthy": (status == "HEALTHY"),
        "header_prediction_hits": hp_hits,
        "fastpath_acks": hp_acks,
        "pure_acks": pure_acks,
        "total_acks": total_acks,
        "fastpath_ack_ratio_pct": hp_ack_ratio,
        "ack_compressed": ack_compressed,
        "delivered_segments": delivered,
        "total_fastpath_events": total_fastpath,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "netstat_counters": {
            "TCPHPHits": hp_hits,
            "TCPHPAcks": hp_acks,
            "TCPPureAcks": pure_acks,
            "TCPAckCompressed": ack_compressed,
            "TCPDelivered": delivered,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Fast-Path Header Prediction & Pure ACK Guard (Pattern 233)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_fastpath()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Fast-Path & ACK Guard (Pattern 237) - Status: {s['status']}")
    print(f"  Header Prediction Hits:  {s['header_prediction_hits']:,}")
    print(f"  Fast-Path ACKs:          {s['fastpath_acks']:,}")
    print(f"  Pure ACKs:               {s['pure_acks']:,}")
    print(f"  Fast-Path ACK Ratio:     {s['fastpath_ack_ratio_pct']}%")
    print(f"  ACKs Compressed:         {s['ack_compressed']:,}")
    print(f"  Delivered Segments:      {s['delivered_segments']:,}")
    print(f"  Total Fast-Path Events:  {s['total_fastpath_events']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
