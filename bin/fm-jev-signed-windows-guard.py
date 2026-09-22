#!/usr/bin/env python3
"""
bin/fm-jev-signed-windows-guard.py - Host Network TCP Broken Window Scaling & Signed Windows Workaround Guard (Pattern 181)

Audits kernel TCP signed windows workaround (tcp_workaround_signed_windows) alongside TCP window scaling
and window progression counters to verify strict RFC 7323 sliding window validation, detect non-compliant
legacy window interpretations, and prevent flow control corruption across high-throughput agent sockets.
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


def audit_signed_windows(
    workaround_file: str = "/proc/sys/net/ipv4/tcp_workaround_signed_windows",
    wscale_file: str = "/proc/sys/net/ipv4/tcp_window_scaling",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    workaround = read_sysctl_int(workaround_file)
    wscale = read_sysctl_int(wscale_file)
    netstat = parse_netstat(netstat_file)

    beyond_window = netstat.get("BeyondWindow", 0)
    zero_window_drop = netstat.get("TCPZeroWindowDrop", 0)
    win_probe = netstat.get("TCPWinProbe", 0)
    out_of_window_icmps = netstat.get("OutOfWindowIcmps", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    if workaround == -1:
        status = "WARNING"
        healthy = False
        issues.append("Unable to read net.ipv4.tcp_workaround_signed_windows sysctl")
        workaround_desc = "Unknown"
    elif workaround == 1:
        status = "WARNING"
        healthy = False
        issues.append("Non-standard signed windows workaround enabled (tcp_workaround_signed_windows=1); relaxed RFC 7323 window validation")
        workaround_desc = "Enabled (legacy bug workaround active, treats signed negative windows as positive)"
    else:
        workaround_desc = "Disabled (strict RFC 7323 unsigned window scaling enforced)"

    if wscale == 0:
        status = "WARNING"
        healthy = False
        issues.append("TCP window scaling disabled (tcp_window_scaling=0); high-throughput streams capped at 64KB window")

    if zero_window_drop > 0:
        status = "WARNING"
        healthy = False
        issues.append(f"Zero-window packet drops detected: {zero_window_drop}")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_workaround_signed_windows": workaround,
        "tcp_workaround_signed_windows_desc": workaround_desc,
        "tcp_window_scaling": wscale,
        "beyond_window": beyond_window,
        "zero_window_drop": zero_window_drop,
        "win_probe": win_probe,
        "out_of_window_icmps": out_of_window_icmps,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_workaround_signed_windows": workaround,
            "tcp_window_scaling": wscale,
        },
        "counters": {
            "BeyondWindow": beyond_window,
            "TCPZeroWindowDrop": zero_window_drop,
            "TCPWinProbe": win_probe,
            "OutOfWindowIcmps": out_of_window_icmps,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Broken Window Scaling & Signed Windows Workaround Guard (Pattern 181)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_signed_windows()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Signed Windows Workaround Guard (Pattern 181) - Status: {s['status']}")
    print(f"  tcp_workaround_signed_windows: {s['tcp_workaround_signed_windows']} ({s['tcp_workaround_signed_windows_desc']})")
    print(f"  tcp_window_scaling:            {s['tcp_window_scaling']} (1 = RFC 7323 enabled)")
    print(f"  Beyond Window Packets:         {s['beyond_window']}")
    print(f"  Zero Window Drops:             {s['zero_window_drop']}")
    print(f"  Window Probes:                 {s['win_probe']}")
    print(f"  Out Of Window ICMPs:           {s['out_of_window_icmps']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
