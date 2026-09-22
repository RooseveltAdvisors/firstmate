#!/usr/bin/env python3
"""
bin/fm-jev-ecn-guard.py - Host Network TCP Explicit Congestion Notification (ECN) Negotiation Guard (Pattern 159)

Audits tcp_ecn and tcp_ecn_fallback sysctls and /proc/net/netstat ECN counters
(TCPDeliveredCE, InCEPkts) to verify RFC 3168 Explicit Congestion Notification
negotiation and CE packet marking behavior, preventing unnecessary packet dropouts
and jitter during high-bandwidth multi-agent streaming sessions.
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


def audit_ecn(
    ecn_file: str = "/proc/sys/net/ipv4/tcp_ecn",
    fallback_file: str = "/proc/sys/net/ipv4/tcp_ecn_fallback",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    ecn = read_sysctl_int(ecn_file)
    fallback = read_sysctl_int(fallback_file)
    netstat = parse_netstat(netstat_file)

    delivered_ce = netstat.get("TCPDeliveredCE", 0)
    in_ce_pkts = netstat.get("InCEPkts", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    if ecn == 0:
        status = "WARNING"
        healthy = False
        issues.append("tcp_ecn is disabled (0), preventing ECN congestion signaling")
    elif ecn < 0:
        issues.append(f"Unable to read tcp_ecn from {ecn_file}")

    if fallback == 0:
        status = "WARNING"
        healthy = False
        issues.append("tcp_ecn_fallback is disabled (0), risking drops if path blocks ECN SYN")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_ecn": ecn,
        "tcp_ecn_fallback": fallback,
        "delivered_ce": delivered_ce,
        "in_ce_pkts": in_ce_pkts,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "counters": {
            "tcp_ecn": ecn,
            "tcp_ecn_fallback": fallback,
            "delivered_ce": delivered_ce,
            "in_ce_pkts": in_ce_pkts,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Explicit Congestion Notification (ECN) Negotiation Guard (Pattern 159)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_ecn()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    mode_str = {0: "disabled", 1: "always", 2: "on incoming requests"}.get(s["tcp_ecn"], str(s["tcp_ecn"]))
    print(f"TCP ECN Negotiation Guard (Pattern 159) - Status: {s['status']}")
    print(f"  tcp_ecn:                   {s['tcp_ecn']} ({mode_str})")
    print(f"  tcp_ecn_fallback:          {s['tcp_ecn_fallback']} (1 = fallback enabled)")
    print(f"  Delivered CE Packets:      {s['delivered_ce']:,}")
    print(f"  Ingress CE Packets:        {s['in_ce_pkts']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
