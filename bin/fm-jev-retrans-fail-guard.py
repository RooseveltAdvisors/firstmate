#!/usr/bin/env python3
"""
bin/fm-jev-retrans-fail-guard.py - Host Network TCP Retransmission Transmit Failure Guard (Pattern 165)

Audits TCP retransmission failures (TCPRetransFail, TCPLostRetransmit) alongside total fast/slow-start
retransmissions and kernel retry thresholds (tcp_retries1, tcp_retries2) from /proc/net/netstat to
verify network driver queue egress health and eliminate silent socket abort stalls.
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


def audit_retrans_fail(
    netstat_file: str = "/proc/net/netstat",
    retries1_file: str = "/proc/sys/net/ipv4/tcp_retries1",
    retries2_file: str = "/proc/sys/net/ipv4/tcp_retries2",
) -> Dict[str, Any]:
    netstat = parse_netstat(netstat_file)
    retries1 = read_sysctl_int(retries1_file)
    retries2 = read_sysctl_int(retries2_file)

    retrans_fail = netstat.get("TCPRetransFail", 0)
    fast_retrans = netstat.get("TCPFastRetrans", 0)
    slowstart_retrans = netstat.get("TCPSlowStartRetrans", 0)
    lost_retrans = netstat.get("TCPLostRetransmit", 0)
    timeouts = netstat.get("TCPTimeouts", 0)
    delivered = netstat.get("TCPDelivered", 0)

    total_retrans = fast_retrans + slowstart_retrans
    fail_ratio = (retrans_fail / (total_retrans + 1)) if total_retrans > 0 else 0.0
    traffic_fail_ratio = (retrans_fail / (delivered + 1)) if delivered > 0 else 0.0

    issues = []
    status = "HEALTHY"
    healthy = True

    if traffic_fail_ratio > 0.01:  # More than 1% of delivered packets failed retransmit
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated retransmission failure rate: {traffic_fail_ratio:.2%} of delivered segments")

    if retries2 < 5:
        status = "WARNING"
        healthy = False
        issues.append(f"Dangerously low tcp_retries2 threshold ({retries2}), risk of premature socket closure")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_retries1": retries1,
        "tcp_retries2": retries2,
        "retrans_fail": retrans_fail,
        "fast_retrans": fast_retrans,
        "slowstart_retrans": slowstart_retrans,
        "total_retrans": total_retrans,
        "lost_retrans": lost_retrans,
        "timeouts": timeouts,
        "delivered": delivered,
        "fail_ratio_pct": round(fail_ratio * 100, 2),
        "traffic_fail_ratio_pct": round(traffic_fail_ratio * 100, 4),
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_retries1": retries1,
            "tcp_retries2": retries2,
        },
        "counters": {
            "TCPRetransFail": retrans_fail,
            "TCPFastRetrans": fast_retrans,
            "TCPSlowStartRetrans": slowstart_retrans,
            "TCPLostRetransmit": lost_retrans,
            "TCPTimeouts": timeouts,
            "TCPDelivered": delivered,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Retransmission Transmit Failure Guard (Pattern 165)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_retrans_fail()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Retransmission Failure Guard (Pattern 165) - Status: {s['status']}")
    print(f"  Retransmission Failures:   {s['retrans_fail']:,} ({s['traffic_fail_ratio_pct']}% of delivered traffic)")
    print(f"  Fast Retransmissions:      {s['fast_retrans']:,}")
    print(f"  Slow-Start Retransmits:    {s['slowstart_retrans']:,}")
    print(f"  Lost Retransmissions:      {s['lost_retrans']:,}")
    print(f"  Total Timeouts:            {s['timeouts']:,}")
    print(f"  tcp_retries1:              {s['tcp_retries1']} (route check threshold)")
    print(f"  tcp_retries2:              {s['tcp_retries2']} (connection abort threshold)")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
