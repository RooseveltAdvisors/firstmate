#!/usr/bin/env python3
"""
bin/fm-jev-backlog-ack-guard.py - Host Network TCP Socket Backlog ACK Deferral Guard (Pattern 177)

Audits kernel TCP socket backlog ACK deferral (tcp_backlog_ack_defer) alongside socket backlog drop
and coalescing counters (TCPBacklogDrop, TCPBacklogCoalesce, ListenOverflows, ListenDrops) to eliminate
socket lock contention and cache bouncing across concurrent multi-agent network request streams.
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


def audit_backlog_ack(
    defer_file: str = "/proc/sys/net/ipv4/tcp_backlog_ack_defer",
    somaxconn_file: str = "/proc/sys/net/core/somaxconn",
    syn_backlog_file: str = "/proc/sys/net/ipv4/tcp_max_syn_backlog",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    defer = read_sysctl_int(defer_file)
    somaxconn = read_sysctl_int(somaxconn_file)
    syn_backlog = read_sysctl_int(syn_backlog_file)
    netstat = parse_netstat(netstat_file)

    backlog_drop = netstat.get("TCPBacklogDrop", 0)
    backlog_coalesce = netstat.get("TCPBacklogCoalesce", 0)
    rcv_collapsed = netstat.get("TCPRcvCollapsed", 0)
    listen_overflows = netstat.get("ListenOverflows", 0)
    listen_drops = netstat.get("ListenDrops", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    if backlog_drop > 10:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated TCP socket backlog drops: {backlog_drop}")

    if listen_overflows > 10:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated listen queue overflows: {listen_overflows}")

    if listen_drops > 10:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated listen queue drops: {listen_drops}")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_backlog_ack_defer": defer,
        "somaxconn": somaxconn,
        "tcp_max_syn_backlog": syn_backlog,
        "backlog_drops": backlog_drop,
        "backlog_coalesced": backlog_coalesce,
        "rcv_collapsed": rcv_collapsed,
        "listen_overflows": listen_overflows,
        "listen_drops": listen_drops,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_backlog_ack_defer": defer,
            "somaxconn": somaxconn,
            "tcp_max_syn_backlog": syn_backlog,
        },
        "counters": {
            "TCPBacklogDrop": backlog_drop,
            "TCPBacklogCoalesce": backlog_coalesce,
            "TCPRcvCollapsed": rcv_collapsed,
            "ListenOverflows": listen_overflows,
            "ListenDrops": listen_drops,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Socket Backlog ACK Deferral Guard (Pattern 177)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_backlog_ack()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Socket Backlog ACK Deferral Guard (Pattern 177) - Status: {s['status']}")
    print(f"  tcp_backlog_ack_defer:        {s['tcp_backlog_ack_defer']} (1 = deferred ACK on lock)")
    print(f"  somaxconn:                    {s['somaxconn']}")
    print(f"  tcp_max_syn_backlog:          {s['tcp_max_syn_backlog']}")
    print(f"  Socket Backlog Drops:         {s['backlog_drops']}")
    print(f"  Backlog Coalesced Segments:   {s['backlog_coalesced']}")
    print(f"  Receive Queue Collapses:      {s['rcv_collapsed']}")
    print(f"  Listen Queue Overflows:       {s['listen_overflows']}")
    print(f"  Listen Queue Drops:           {s['listen_drops']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
