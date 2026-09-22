#!/usr/bin/env python3
"""
bin/fm-jev-tw-reuse-delay-guard.py - Host Network TCP TIME_WAIT Reuse Delay & Socket Recycled Protection Guard (Pattern 183)

Audits kernel TCP TIME_WAIT reuse delay (tcp_tw_reuse_delay) and reuse mode (tcp_tw_reuse) alongside
TIME_WAIT recycling and PAWS rejection counters in /proc/net/netstat to verify safe socket port recycling,
prevent stale segment collision in recycled connections, and eliminate TIME_WAIT hash table overflows.
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


def audit_tw_reuse_delay(
    delay_file: str = "/proc/sys/net/ipv4/tcp_tw_reuse_delay",
    reuse_file: str = "/proc/sys/net/ipv4/tcp_tw_reuse",
    fin_timeout_file: str = "/proc/sys/net/ipv4/tcp_fin_timeout",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    tw_reuse_delay_ms = read_sysctl_int(delay_file)
    tw_reuse = read_sysctl_int(reuse_file)
    fin_timeout = read_sysctl_int(fin_timeout_file)
    netstat = parse_netstat(netstat_file)

    tw_total = netstat.get("TW", 0)
    tw_recycled = netstat.get("TWRecycled", 0)
    tw_killed = netstat.get("TWKilled", 0)
    paws_tw = netstat.get("PAWSTimewait", 0)
    tw_overflow = netstat.get("TCPTimeWaitOverflow", 0)
    ack_skipped_tw = netstat.get("TCPACKSkippedTimeWait", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    if tw_reuse_delay_ms == -1:
        status = "WARNING"
        healthy = False
        issues.append("Unable to read net.ipv4.tcp_tw_reuse_delay sysctl")
    elif tw_reuse_delay_ms < 100:
        status = "WARNING"
        healthy = False
        issues.append(f"Aggressively low TIME_WAIT reuse delay: {tw_reuse_delay_ms}ms (recommended: >=1000ms)")

    if tw_reuse == 0:
        status = "WARNING"
        healthy = False
        issues.append("TCP TIME_WAIT reuse disabled (tcp_tw_reuse=0); risk of ephemeral port exhaustion under burst traffic")

    if tw_overflow > 0:
        status = "WARNING"
        healthy = False
        issues.append(f"TIME_WAIT hash table overflow detected: {tw_overflow}")

    if tw_killed > 100:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated TIME_WAIT killed sockets: {tw_killed}")

    tw_reuse_desc = {
        0: "Disabled",
        1: "Global enabled",
        2: "Enabled with RFC 1323 timestamp safety for loopback/outbound",
    }.get(tw_reuse, f"Unknown ({tw_reuse})")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_tw_reuse_delay_ms": tw_reuse_delay_ms,
        "tcp_tw_reuse": tw_reuse,
        "tcp_tw_reuse_desc": tw_reuse_desc,
        "tcp_fin_timeout_sec": fin_timeout,
        "tw_total": tw_total,
        "tw_recycled": tw_recycled,
        "tw_killed": tw_killed,
        "paws_timewait": paws_tw,
        "tw_overflow": tw_overflow,
        "ack_skipped_timewait": ack_skipped_tw,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_tw_reuse_delay_ms": tw_reuse_delay_ms,
            "tcp_tw_reuse": tw_reuse,
            "tcp_fin_timeout_sec": fin_timeout,
        },
        "counters": {
            "TW": tw_total,
            "TWRecycled": tw_recycled,
            "TWKilled": tw_killed,
            "PAWSTimewait": paws_tw,
            "TCPTimeWaitOverflow": tw_overflow,
            "TCPACKSkippedTimeWait": ack_skipped_tw,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP TIME_WAIT Reuse Delay & Socket Recycled Protection Guard (Pattern 183)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_tw_reuse_delay()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP TIME_WAIT Reuse Delay Guard (Pattern 183) - Status: {s['status']}")
    print(f"  tcp_tw_reuse_delay:           {s['tcp_tw_reuse_delay_ms']} ms")
    print(f"  tcp_tw_reuse:                 {s['tcp_tw_reuse']} ({s['tcp_tw_reuse_desc']})")
    print(f"  tcp_fin_timeout:              {s['tcp_fin_timeout_sec']} s")
    print(f"  Total TIME_WAIT Entries:      {s['tw_total']}")
    print(f"  Recycled Sockets:             {s['tw_recycled']}")
    print(f"  PAWS TIME_WAIT Drops:         {s['paws_timewait']}")
    print(f"  TIME_WAIT Overflows:          {s['tw_overflow']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
