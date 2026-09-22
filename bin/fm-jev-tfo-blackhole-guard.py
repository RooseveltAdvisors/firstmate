#!/usr/bin/env python3
"""
bin/fm-jev-tfo-blackhole-guard.py - Host Network TCP Fast Open (TFO) Blackhole Fallback & Active Probing Guard (Pattern 174)

Audits kernel TCP Fast Open (RFC 7413) bitmap mode (tcp_fastopen) and blackhole timeout
(tcp_fastopen_blackhole_timeout_sec) alongside netstat TFO counters (TCPFastOpenActive,
TCPFastOpenActiveFail, TCPFastOpenBlackhole, TCPFastOpenListenOverflow) to verify 0-RTT
handshake acceleration stability and middlebox blackhole recovery across agent connections.
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


def audit_tfo_blackhole(
    fastopen_file: str = "/proc/sys/net/ipv4/tcp_fastopen",
    blackhole_timeout_file: str = "/proc/sys/net/ipv4/tcp_fastopen_blackhole_timeout_sec",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    fastopen = read_sysctl_int(fastopen_file)
    blackhole_timeout = read_sysctl_int(blackhole_timeout_file)
    netstat = parse_netstat(netstat_file)

    active_success = netstat.get("TCPFastOpenActive", 0)
    active_fail = netstat.get("TCPFastOpenActiveFail", 0)
    passive_success = netstat.get("TCPFastOpenPassive", 0)
    passive_fail = netstat.get("TCPFastOpenPassiveFail", 0)
    listen_overflow = netstat.get("TCPFastOpenListenOverflow", 0)
    cookie_reqd = netstat.get("TCPFastOpenCookieReqd", 0)
    blackhole_events = netstat.get("TCPFastOpenBlackhole", 0)
    alt_key = netstat.get("TCPFastOpenPassiveAltKey", 0)

    # Bitmap decode: bit 0 (1) = client TFO enabled, bit 1 (2) = server TFO enabled
    client_enabled = bool(fastopen & 1) if fastopen >= 0 else False
    server_enabled = bool(fastopen & 2) if fastopen >= 0 else False

    issues = []
    status = "HEALTHY"
    healthy = True

    if blackhole_events > 10:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated TFO blackholing events detected: {blackhole_events}")

    if listen_overflow > 20:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated TFO listen queue overflows: {listen_overflow}")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_fastopen": fastopen,
        "client_tfo_enabled": client_enabled,
        "server_tfo_enabled": server_enabled,
        "blackhole_timeout_sec": blackhole_timeout,
        "active_success": active_success,
        "active_fail": active_fail,
        "passive_success": passive_success,
        "passive_fail": passive_fail,
        "listen_overflow": listen_overflow,
        "cookie_reqd": cookie_reqd,
        "blackhole_events": blackhole_events,
        "alt_key": alt_key,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_fastopen": fastopen,
            "tcp_fastopen_blackhole_timeout_sec": blackhole_timeout,
        },
        "counters": {
            "TCPFastOpenActive": active_success,
            "TCPFastOpenActiveFail": active_fail,
            "TCPFastOpenPassive": passive_success,
            "TCPFastOpenPassiveFail": passive_fail,
            "TCPFastOpenListenOverflow": listen_overflow,
            "TCPFastOpenCookieReqd": cookie_reqd,
            "TCPFastOpenBlackhole": blackhole_events,
            "TCPFastOpenPassiveAltKey": alt_key,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Fast Open (TFO) Blackhole Fallback & Active Probing Guard (Pattern 174)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_tfo_blackhole()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Fast Open Blackhole Guard (Pattern 174) - Status: {s['status']}")
    print(f"  tcp_fastopen:                 {s['tcp_fastopen']} (client={s['client_tfo_enabled']}, server={s['server_tfo_enabled']})")
    print(f"  blackhole_timeout_sec:        {s['blackhole_timeout_sec']} s")
    print(f"  Active TFO Handshakes:        {s['active_success']}")
    print(f"  Active TFO Fallbacks:         {s['active_fail']}")
    print(f"  Passive TFO Accepted:         {s['passive_success']}")
    print(f"  Passive TFO Failures:         {s['passive_fail']}")
    print(f"  Listen Overflows:             {s['listen_overflow']}")
    print(f"  Cookie Reqd:                  {s['cookie_reqd']}")
    print(f"  Blackhole Events:             {s['blackhole_events']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
