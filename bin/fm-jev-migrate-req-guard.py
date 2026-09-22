#!/usr/bin/env python3
"""
bin/fm-jev-migrate-req-guard.py - Host Network TCP Listener eBPF Connection Migration Guard (Pattern 178)

Audits kernel TCP connection migration behavior (tcp_migrate_req) alongside eBPF reuseport migration
counters (TCPMigrateReqSuccess, TCPMigrateReqFailure, EmbryonicRsts, ListenDrops) to verify zero-downtime
listener socket handover and eliminate embryonic resets during service restarts across multi-agent nodes.
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


def audit_migrate_req(
    migrate_file: str = "/proc/sys/net/ipv4/tcp_migrate_req",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    migrate_req = read_sysctl_int(migrate_file)
    netstat = parse_netstat(netstat_file)

    migrate_success = netstat.get("TCPMigrateReqSuccess", 0)
    migrate_failure = netstat.get("TCPMigrateReqFailure", 0)
    embryonic_rsts = netstat.get("EmbryonicRsts", 0)
    listen_overflows = netstat.get("ListenOverflows", 0)
    listen_drops = netstat.get("ListenDrops", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    if migrate_failure > 10:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated TCP connection migration failures: {migrate_failure}")

    if embryonic_rsts > 50:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated embryonic connection resets: {embryonic_rsts}")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_migrate_req": migrate_req,
        "migrate_success": migrate_success,
        "migrate_failure": migrate_failure,
        "embryonic_resets": embryonic_rsts,
        "listen_overflows": listen_overflows,
        "listen_drops": listen_drops,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_migrate_req": migrate_req,
        },
        "counters": {
            "TCPMigrateReqSuccess": migrate_success,
            "TCPMigrateReqFailure": migrate_failure,
            "EmbryonicRsts": embryonic_rsts,
            "ListenOverflows": listen_overflows,
            "ListenDrops": listen_drops,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Listener eBPF Connection Migration Guard (Pattern 178)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_migrate_req()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Listener Connection Migration Guard (Pattern 178) - Status: {s['status']}")
    print(f"  tcp_migrate_req:              {s['tcp_migrate_req']} (1 = eBPF listener migration enabled)")
    print(f"  Migration Successes:          {s['migrate_success']}")
    print(f"  Migration Failures:           {s['migrate_failure']}")
    print(f"  Embryonic Resets:             {s['embryonic_resets']}")
    print(f"  Listen Overflows:             {s['listen_overflows']}")
    print(f"  Listen Drops:                 {s['listen_drops']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
