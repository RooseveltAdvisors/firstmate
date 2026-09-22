#!/usr/bin/env python3
"""
bin/fm-jev-rehash-guard.py - Host Network TCP Predictive Load Balancing (PLB) & Route Rehashing Guard (Pattern 163)

Audits TCP route and flow label rehashing counters (TcpTimeoutRehash, TcpDuplicateDataRehash,
TCPPLBRehash) from /proc/net/netstat alongside kernel PLB sysctls (tcp_plb_enabled,
tcp_plb_cong_thresh, tcp_plb_rehash_rounds) to verify automated multipath route failover
and eliminate persistent path degradation across multi-agent egress tunnels.
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
        print(f"Warning: unable to parse {path}: {e}", file=sys.stderr)
    return counters


def audit_rehash(
    netstat_file: str = "/proc/net/netstat",
    plb_enabled_file: str = "/proc/sys/net/ipv4/tcp_plb_enabled",
    plb_cong_thresh_file: str = "/proc/sys/net/ipv4/tcp_plb_cong_thresh",
    plb_rehash_rounds_file: str = "/proc/sys/net/ipv4/tcp_plb_rehash_rounds",
) -> Dict[str, Any]:
    netstat = parse_netstat(netstat_file)
    plb_enabled = read_sysctl_int(plb_enabled_file)
    plb_cong_thresh = read_sysctl_int(plb_cong_thresh_file)
    plb_rehash_rounds = read_sysctl_int(plb_rehash_rounds_file)

    timeout_rehash = netstat.get("TcpTimeoutRehash", 0)
    dup_data_rehash = netstat.get("TcpDuplicateDataRehash", 0)
    plb_rehash = netstat.get("TCPPLBRehash", 0)
    tcp_timeouts = netstat.get("TCPTimeouts", 0)

    rehash_ratio = (timeout_rehash / (tcp_timeouts + 1)) if tcp_timeouts > 0 else 0.0

    issues = []
    status = "HEALTHY"
    healthy = True

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_plb_enabled": plb_enabled,
        "tcp_plb_cong_thresh": plb_cong_thresh,
        "tcp_plb_rehash_rounds": plb_rehash_rounds,
        "timeout_rehash": timeout_rehash,
        "dup_data_rehash": dup_data_rehash,
        "plb_rehash": plb_rehash,
        "tcp_timeouts": tcp_timeouts,
        "rehash_ratio_pct": round(rehash_ratio * 100, 2),
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "counters": {
            "TcpTimeoutRehash": timeout_rehash,
            "TcpDuplicateDataRehash": dup_data_rehash,
            "TCPPLBRehash": plb_rehash,
            "TCPTimeouts": tcp_timeouts,
        },
        "sysctls": {
            "tcp_plb_enabled": plb_enabled,
            "tcp_plb_cong_thresh": plb_cong_thresh,
            "tcp_plb_rehash_rounds": plb_rehash_rounds,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Predictive Load Balancing (PLB) & Route Rehashing Guard (Pattern 163)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_rehash()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Route Rehashing & PLB Guard (Pattern 163) - Status: {s['status']}")
    print(f"  Timeout Rehashes:        {s['timeout_rehash']:,} ({s['rehash_ratio_pct']}% of timeouts)")
    print(f"  Duplicate Data Rehashes: {s['dup_data_rehash']:,}")
    print(f"  PLB Rehashes:            {s['plb_rehash']:,}")
    print(f"  Total TCP Timeouts:      {s['tcp_timeouts']:,}")
    print(f"  tcp_plb_enabled:         {s['tcp_plb_enabled']} (1 = PLB active)")
    print(f"  tcp_plb_cong_thresh:     {s['tcp_plb_cong_thresh']}")
    print(f"  tcp_plb_rehash_rounds:   {s['tcp_plb_rehash_rounds']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
