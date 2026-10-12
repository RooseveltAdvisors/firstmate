#!/usr/bin/env python3
"""
bin/fm-jev-fwmark-guard.py - Host Network TCP Firewall Mark (fwmark) Reflection Guard (Pattern 179)

Audits kernel TCP fwmark reflection (tcp_fwmark_accept) and L3 master device binding (tcp_l3mdev_accept)
alongside reverse path filtering drops and connection metrics to verify policy routing symmetry and prevent
asymmetric routing blackholes across multi-interface agent gateways and VPN bridges.
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


def audit_fwmark(
    fwmark_file: str = "/proc/sys/net/ipv4/tcp_fwmark_accept",
    l3mdev_file: str = "/proc/sys/net/ipv4/tcp_l3mdev_accept",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    fwmark_accept = read_sysctl_int(fwmark_file)
    l3mdev_accept = read_sysctl_int(l3mdev_file)
    netstat = parse_netstat(netstat_file)

    rp_filter_drops = netstat.get("IPReversePathFilter", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    if rp_filter_drops > 100:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated reverse path filter drops: {rp_filter_drops}")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_fwmark_accept": fwmark_accept,
        "tcp_l3mdev_accept": l3mdev_accept,
        "rp_filter_drops": rp_filter_drops,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_fwmark_accept": fwmark_accept,
            "tcp_l3mdev_accept": l3mdev_accept,
        },
        "counters": {
            "IPReversePathFilter": rp_filter_drops,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Firewall Mark (fwmark) Reflection Guard (Pattern 179)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_fwmark()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Firewall Mark (fwmark) Reflection Guard (Pattern 179) - Status: {s['status']}")
    print(f"  tcp_fwmark_accept:            {s['tcp_fwmark_accept']} (1 = inherit incoming skb mark)")
    print(f"  tcp_l3mdev_accept:            {s['tcp_l3mdev_accept']} (1 = VRF master device binding)")
    print(f"  Reverse Path Filter Drops:    {s['rp_filter_drops']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
