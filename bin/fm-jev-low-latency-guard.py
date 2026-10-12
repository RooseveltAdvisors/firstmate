#!/usr/bin/env python3
"""
bin/fm-jev-low-latency-guard.py - Host Network TCP Low-Latency & Listen Backlog Guard (Pattern 171)

Audits kernel TCP low-latency preemption (tcp_low_latency) and listen backlog overflow behavior
(tcp_abort_on_overflow) alongside listen queue netstat counters (ListenOverflows, ListenDrops) to
verify connection handshake defense and eliminate silent application listen queue drops.
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


def audit_low_latency(
    low_latency_file: str = "/proc/sys/net/ipv4/tcp_low_latency",
    abort_overflow_file: str = "/proc/sys/net/ipv4/tcp_abort_on_overflow",
    syn_backlog_file: str = "/proc/sys/net/ipv4/tcp_max_syn_backlog",
    somaxconn_file: str = "/proc/sys/net/core/somaxconn",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    low_latency = read_sysctl_int(low_latency_file)
    abort_overflow = read_sysctl_int(abort_overflow_file)
    syn_backlog = read_sysctl_int(syn_backlog_file)
    somaxconn = read_sysctl_int(somaxconn_file)
    netstat = parse_netstat(netstat_file)

    listen_overflows = netstat.get("ListenOverflows", 0)
    listen_drops = netstat.get("ListenDrops", 0)
    embryonic_rsts = netstat.get("EmbryonicRsts", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    if listen_overflows > 10:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated listen queue overflows: {listen_overflows}")

    if listen_drops > 10:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated listen queue connection drops: {listen_drops}")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_low_latency": low_latency,
        "tcp_abort_on_overflow": abort_overflow,
        "tcp_max_syn_backlog": syn_backlog,
        "somaxconn": somaxconn,
        "listen_overflows": listen_overflows,
        "listen_drops": listen_drops,
        "embryonic_rsts": embryonic_rsts,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_low_latency": low_latency,
            "tcp_abort_on_overflow": abort_overflow,
            "tcp_max_syn_backlog": syn_backlog,
            "somaxconn": somaxconn,
        },
        "counters": {
            "ListenOverflows": listen_overflows,
            "ListenDrops": listen_drops,
            "EmbryonicRsts": embryonic_rsts,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Low-Latency & Listen Backlog Guard (Pattern 171)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_low_latency()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Low-Latency & Backlog Guard (Pattern 171) - Status: {s['status']}")
    print(f"  tcp_low_latency:           {s['tcp_low_latency']} (0 = throughput-optimized)")
    print(f"  tcp_abort_on_overflow:     {s['tcp_abort_on_overflow']} (0 = backoff retry on burst)")
    print(f"  tcp_max_syn_backlog:       {s['tcp_max_syn_backlog']}")
    print(f"  somaxconn:                 {s['somaxconn']}")
    print(f"  Listen Overflows:          {s['listen_overflows']}")
    print(f"  Listen Drops:              {s['listen_drops']}")
    print(f"  Embryonic Resets:          {s['embryonic_rsts']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
