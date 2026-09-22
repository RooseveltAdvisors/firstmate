#!/usr/bin/env python3
"""
bin/fm-jev-autocork-guard.py - Host Network TCP Autocorking & Coalescence Guard (Pattern 194)

Audits kernel TCP write request coalescing configuration (tcp_autocorking, tcp_notsent_lowat)
and packet coalescing telemetry from /proc/net/netstat (TCPAutoCorking, TCPOrigDataSent,
TCPBacklogCoalesce, TCPRcvCoalesce). Verifies intelligent sub-MSS packet batching to maximize
network device throughput and minimize CPU softirq overhead without introducing latency delays
into small interactive JSON-RPC agent messages.
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List


def read_sysctl_int(path: str) -> int:
    if not os.path.exists(path):
        return -1
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception as e:
        print(f"Warning: unable to read {path}: {e}", file=sys.stderr)
        return -1


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


def audit_autocorking(
    tcp_autocorking_file: str = "/proc/sys/net/ipv4/tcp_autocorking",
    tcp_notsent_lowat_file: str = "/proc/sys/net/ipv4/tcp_notsent_lowat",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    autocorking = read_sysctl_int(tcp_autocorking_file)
    notsent_lowat = read_sysctl_int(tcp_notsent_lowat_file)

    netstat = parse_netstat_ext(netstat_file)

    autocork_segs = netstat.get("TCPAutoCorking", 0)
    orig_data_sent = netstat.get("TCPOrigDataSent", 0)
    backlog_coalesce = netstat.get("TCPBacklogCoalesce", 0)
    rcv_coalesce = netstat.get("TCPRcvCoalesce", 0)

    autocork_ratio = round((autocork_segs / orig_data_sent * 100.0), 4) if orig_data_sent > 0 else 0.0

    issues: List[str] = []
    status = "HEALTHY"

    # Critical conditions
    if autocorking == 0 and notsent_lowat == 0:
        issues.append("tcp_autocorking is disabled and tcp_notsent_lowat is 0: severe fragmentation of consecutive write requests")
        status = "CRITICAL"

    # Warning conditions
    if status != "CRITICAL":
        if autocorking == 0:
            issues.append("tcp_autocorking is 0 (disabled): sub-MSS write requests sent immediately rather than batched")
            status = "WARNING"
        if autocork_ratio >= 25.0:
            issues.append(f"Auto-corking ratio ({autocork_ratio}%) exceeds 25.0% warning threshold: excessive write buffering")
            status = "WARNING"

    summary = {
        "status": status,
        "healthy": (status == "HEALTHY"),
        "tcp_autocorking": autocorking,
        "tcp_notsent_lowat": notsent_lowat,
        "autocorked_segments": autocork_segs,
        "orig_data_sent": orig_data_sent,
        "autocork_ratio_pct": autocork_ratio,
        "backlog_coalesce": backlog_coalesce,
        "rcv_coalesce": rcv_coalesce,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_autocorking": autocorking,
            "tcp_notsent_lowat": notsent_lowat,
        },
        "netstat_counters": {
            "TCPAutoCorking": autocork_segs,
            "TCPOrigDataSent": orig_data_sent,
            "TCPBacklogCoalesce": backlog_coalesce,
            "TCPRcvCoalesce": rcv_coalesce,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Autocorking & Coalescence Guard (Pattern 194)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_autocorking()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Autocorking & Coalescence Guard (Pattern 194) - Status: {s['status']}")
    print(f"  tcp_autocorking:       {s['tcp_autocorking']} ({'enabled' if s['tcp_autocorking'] == 1 else 'disabled'})")
    print(f"  tcp_notsent_lowat:     {s['tcp_notsent_lowat']:,} bytes")
    print(f"  Auto-Corked Segments:  {s['autocorked_segments']:,}")
    print(f"  Original Data Sent:    {s['orig_data_sent']:,}")
    print(f"  Auto-Corking Ratio:    {s['autocork_ratio_pct']}%")
    print(f"  Backlog Coalesced:     {s['backlog_coalesce']:,}")
    print(f"  Receive Coalesced:     {s['rcv_coalesce']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
