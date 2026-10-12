#!/usr/bin/env python3
"""
bin/fm-jev-window-shrink-guard.py - Host Network TCP Window Shrinking & Min MSS Guard (Pattern 169)

Audits kernel TCP window shrinking compliance (tcp_shrink_window), signed window compatibility
(tcp_workaround_signed_windows), and minimum allowable sender MSS (tcp_min_snd_mss) to ensure
strict RFC 793 sliding window stability and prevent micro-fragmentation throughput degradation.
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


def audit_window_shrink(
    shrink_window_file: str = "/proc/sys/net/ipv4/tcp_shrink_window",
    signed_windows_file: str = "/proc/sys/net/ipv4/tcp_workaround_signed_windows",
    min_snd_mss_file: str = "/proc/sys/net/ipv4/tcp_min_snd_mss",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    shrink_window = read_sysctl_int(shrink_window_file)
    signed_windows = read_sysctl_int(signed_windows_file)
    min_snd_mss = read_sysctl_int(min_snd_mss_file)
    netstat = parse_netstat(netstat_file)

    beyond_window = netstat.get("BeyondWindow", 0)
    out_of_window_icmps = netstat.get("OutOfWindowIcmps", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    if shrink_window == 1:
        status = "WARNING"
        healthy = False
        issues.append("tcp_shrink_window is enabled (1), violating strict RFC 793 window invariance")

    if min_snd_mss > 0 and min_snd_mss < 48:
        status = "WARNING"
        healthy = False
        issues.append(f"Dangerously low tcp_min_snd_mss ({min_snd_mss}), risk of tinygram packet floods")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_shrink_window": shrink_window,
        "tcp_workaround_signed_windows": signed_windows,
        "tcp_min_snd_mss": min_snd_mss,
        "beyond_window_packets": beyond_window,
        "out_of_window_icmps": out_of_window_icmps,
        "rfc793_compliant": shrink_window == 0,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_shrink_window": shrink_window,
            "tcp_workaround_signed_windows": signed_windows,
            "tcp_min_snd_mss": min_snd_mss,
        },
        "counters": {
            "BeyondWindow": beyond_window,
            "OutOfWindowIcmps": out_of_window_icmps,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Window Shrinking & Min MSS Guard (Pattern 169)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_window_shrink()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Window Shrink Guard (Pattern 169) - Status: {s['status']}")
    print(f"  tcp_shrink_window:             {s['tcp_shrink_window']} (0 = RFC 793 invariant)")
    print(f"  tcp_workaround_signed_windows: {s['tcp_workaround_signed_windows']}")
    print(f"  tcp_min_snd_mss:               {s['tcp_min_snd_mss']} B")
    print(f"  Beyond Window Packets:         {s['beyond_window_packets']:,}")
    print(f"  Out of Window ICMPs:           {s['out_of_window_icmps']:,}")
    print(f"  RFC 793 Compliant:             {s['rfc793_compliant']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
