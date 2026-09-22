#!/usr/bin/env python3
"""
bin/fm-jev-sack-slack-guard.py - Host Network TCP SACK Compression Slack & Delay Jitter Guard (Pattern 184)

Audits kernel TCP SACK compression slack window (tcp_comp_sack_slack_ns), delay (tcp_comp_sack_delay_ns),
and batch count (tcp_comp_sack_nr) alongside compressed ACK counters in /proc/net/netstat to verify
bounded reverse-path ACK decimation, eliminate timer wheel interrupt storms, and prevent latency spikes
across high-frequency JSON-RPC agent streams.
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


def audit_sack_slack(
    slack_file: str = "/proc/sys/net/ipv4/tcp_comp_sack_slack_ns",
    delay_file: str = "/proc/sys/net/ipv4/tcp_comp_sack_delay_ns",
    nr_file: str = "/proc/sys/net/ipv4/tcp_comp_sack_nr",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    slack_ns = read_sysctl_int(slack_file)
    delay_ns = read_sysctl_int(delay_file)
    sack_nr = read_sysctl_int(nr_file)
    netstat = parse_netstat(netstat_file)

    ack_compressed = netstat.get("TCPAckCompressed", 0)
    delayed_acks = netstat.get("DelayedACKs", 0)
    delayed_ack_lost = netstat.get("DelayedACKLost", 0)
    delayed_ack_locked = netstat.get("DelayedACKLocked", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    if slack_ns == -1:
        status = "WARNING"
        healthy = False
        issues.append("Unable to read net.ipv4.tcp_comp_sack_slack_ns sysctl")
    elif slack_ns > 5000000:  # > 5ms slack
        status = "WARNING"
        healthy = False
        issues.append(f"Excessive SACK compression slack window: {slack_ns}ns ({slack_ns / 1e6:.1f}ms, recommended: <=1ms)")

    if delay_ns == -1:
        status = "WARNING"
        healthy = False
        issues.append("Unable to read net.ipv4.tcp_comp_sack_delay_ns sysctl")
    elif delay_ns > 10000000:  # > 10ms delay
        status = "WARNING"
        healthy = False
        issues.append(f"Excessive SACK compression delay: {delay_ns}ns ({delay_ns / 1e6:.1f}ms, recommended: <=5ms)")

    if sack_nr == 0:
        status = "WARNING"
        healthy = False
        issues.append("SACK compression packet threshold is 0 (compression disabled)")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_comp_sack_slack_ns": slack_ns,
        "tcp_comp_sack_slack_us": slack_ns / 1000.0 if slack_ns >= 0 else -1,
        "tcp_comp_sack_delay_ns": delay_ns,
        "tcp_comp_sack_delay_ms": delay_ns / 1e6 if delay_ns >= 0 else -1,
        "tcp_comp_sack_nr": sack_nr,
        "ack_compressed": ack_compressed,
        "delayed_acks": delayed_acks,
        "delayed_ack_lost": delayed_ack_lost,
        "delayed_ack_locked": delayed_ack_locked,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_comp_sack_slack_ns": slack_ns,
            "tcp_comp_sack_delay_ns": delay_ns,
            "tcp_comp_sack_nr": sack_nr,
        },
        "counters": {
            "TCPAckCompressed": ack_compressed,
            "DelayedACKs": delayed_acks,
            "DelayedACKLost": delayed_ack_lost,
            "DelayedACKLocked": delayed_ack_locked,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP SACK Compression Slack & Delay Jitter Guard (Pattern 184)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_sack_slack()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP SACK Compression Slack Guard (Pattern 184) - Status: {s['status']}")
    print(f"  tcp_comp_sack_slack_ns:       {s['tcp_comp_sack_slack_ns']} ns ({s['tcp_comp_sack_slack_us']:.1f} µs)")
    print(f"  tcp_comp_sack_delay_ns:       {s['tcp_comp_sack_delay_ns']} ns ({s['tcp_comp_sack_delay_ms']:.2f} ms)")
    print(f"  tcp_comp_sack_nr:             {s['tcp_comp_sack_nr']} packets")
    print(f"  Compressed ACKs Sent:         {s['ack_compressed']}")
    print(f"  Delayed ACKs Sent:            {s['delayed_acks']}")
    print(f"  Delayed ACK Timeouts:         {s['delayed_ack_lost']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
