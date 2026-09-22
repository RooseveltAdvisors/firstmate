#!/usr/bin/env python3
"""
bin/fm-jev-syncookies-guard.py - Host Network TCP SYN Cookie Storm & Syncookies Recv Guard (Pattern 192)

Audits kernel TCP SYN flood protection and syncookie defense configuration (tcp_syncookies,
somaxconn, tcp_max_syn_backlog) along with netstat syncookie counters (SyncookiesSent,
SyncookiesRecv, SyncookiesFailed, EmbryonicRsts, ListenDrops, ListenOverflows).
Ensures zero-downtime protection against SYN flood attacks without premature connection resets,
verifies listen backlog sizing, and detects syncookie validation failures across public endpoints.
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


def audit_syncookies(
    tcp_syncookies_file: str = "/proc/sys/net/ipv4/tcp_syncookies",
    somaxconn_file: str = "/proc/sys/net/core/somaxconn",
    max_syn_backlog_file: str = "/proc/sys/net/ipv4/tcp_max_syn_backlog",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    tcp_syncookies = read_sysctl_int(tcp_syncookies_file)
    somaxconn = read_sysctl_int(somaxconn_file)
    max_syn_backlog = read_sysctl_int(max_syn_backlog_file)

    netstat = parse_netstat_ext(netstat_file)

    syncookies_sent = netstat.get("SyncookiesSent", 0)
    syncookies_recv = netstat.get("SyncookiesRecv", 0)
    syncookies_failed = netstat.get("SyncookiesFailed", 0)
    embryonic_rsts = netstat.get("EmbryonicRsts", 0)
    listen_drops = netstat.get("ListenDrops", 0)
    listen_overflows = netstat.get("ListenOverflows", 0)

    issues: List[str] = []
    status = "HEALTHY"

    # Critical conditions
    if tcp_syncookies == 0:
        issues.append("tcp_syncookies is 0 (disabled): host is unprotected against SYN flood exhaustion")
        status = "CRITICAL"
    if syncookies_failed > 1000:
        issues.append(f"SyncookiesFailed ({syncookies_failed}) > 1000: widespread syncookie validation rejection")
        status = "CRITICAL"
    if listen_drops > 1000:
        issues.append(f"ListenDrops ({listen_drops}) > 1000: severe drop rate of incoming connections")
        status = "CRITICAL"

    # Warning conditions
    if status != "CRITICAL":
        if syncookies_sent > 1000:
            issues.append(f"SyncookiesSent ({syncookies_sent}) > 1000: listen queue frequently exhausted under traffic burst")
            status = "WARNING"
        if listen_overflows > 100:
            issues.append(f"ListenOverflows ({listen_overflows}) > 100: listen socket queues overflowing")
            status = "WARNING"
        if somaxconn > 0 and somaxconn < 1024:
            issues.append(f"somaxconn ({somaxconn}) < 1024: low socket listen backlog may bottleneck bursts")
            status = "WARNING"
        if max_syn_backlog > 0 and max_syn_backlog < 1024:
            issues.append(f"tcp_max_syn_backlog ({max_syn_backlog}) < 1024: low SYN backlog may trigger premature syncookies")
            status = "WARNING"

    syncookies_desc = {
        0: "disabled",
        1: "enabled on backlog overflow",
        2: "unconditionally enabled",
    }.get(tcp_syncookies, f"unknown ({tcp_syncookies})")

    summary = {
        "status": status,
        "healthy": (status == "HEALTHY"),
        "tcp_syncookies": tcp_syncookies,
        "tcp_syncookies_mode": syncookies_desc,
        "somaxconn": somaxconn,
        "tcp_max_syn_backlog": max_syn_backlog,
        "syncookies_sent": syncookies_sent,
        "syncookies_recv": syncookies_recv,
        "syncookies_failed": syncookies_failed,
        "embryonic_rsts": embryonic_rsts,
        "listen_drops": listen_drops,
        "listen_overflows": listen_overflows,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_syncookies": tcp_syncookies,
            "somaxconn": somaxconn,
            "tcp_max_syn_backlog": max_syn_backlog,
        },
        "netstat_counters": {
            "SyncookiesSent": syncookies_sent,
            "SyncookiesRecv": syncookies_recv,
            "SyncookiesFailed": syncookies_failed,
            "EmbryonicRsts": embryonic_rsts,
            "ListenDrops": listen_drops,
            "ListenOverflows": listen_overflows,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP SYN Cookie Storm & Syncookies Recv Guard (Pattern 192)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_syncookies()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP SYN Cookie Guard (Pattern 192) - Status: {s['status']}")
    print(f"  tcp_syncookies:        {s['tcp_syncookies']} ({s['tcp_syncookies_mode']})")
    print(f"  somaxconn:             {s['somaxconn']:,}")
    print(f"  tcp_max_syn_backlog:   {s['tcp_max_syn_backlog']:,}")
    print(f"  Syncookies Sent:       {s['syncookies_sent']:,}")
    print(f"  Syncookies Received:   {s['syncookies_recv']:,}")
    print(f"  Syncookies Failed:     {s['syncookies_failed']:,}")
    print(f"  Embryonic Resets:      {s['embryonic_rsts']:,}")
    print(f"  Listen Queue Drops:    {s['listen_drops']:,}")
    print(f"  Listen Overflows:      {s['listen_overflows']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
