#!/usr/bin/env python3
"""
bin/fm-jev-thin-timeout-guard.py - Host Network TCP Thin-Stream Linear Timeout & Latency Optimization Guard (Pattern 235)

Audits tcp_thin_linear_timeouts and tcp_syn_linear_timeouts sysctls and
retransmission timeout metrics (TCPTimeouts, TCPSpuriousRTOs, TCPLossFailures)
to verify thin-stream low-latency scheduling, preventing excessive exponential
backoff stalls during interactive multi-agent JSON-RPC and streaming token exchanges.
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict


def read_sysctl(path: str) -> int:
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


def audit_thin_timeouts(
    thin_timeouts_file: str = "/proc/sys/net/ipv4/tcp_thin_linear_timeouts",
    syn_timeouts_file: str = "/proc/sys/net/ipv4/tcp_syn_linear_timeouts",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    thin_linear = read_sysctl(thin_timeouts_file)
    syn_linear = read_sysctl(syn_timeouts_file)
    netstat = parse_netstat(netstat_file)

    timeouts = netstat.get("TCPTimeouts", 0)
    spurious_rtos = netstat.get("TCPSpuriousRTOs", 0)
    loss_failures = netstat.get("TCPLossFailures", 0)

    spurious_ratio_pct = 0.0
    if timeouts > 0:
        spurious_ratio_pct = round((spurious_rtos / timeouts) * 100.0, 3)

    issues = []
    status = "HEALTHY"
    healthy = True

    if syn_linear == 0:
        status = "WARNING"
        healthy = False
        issues.append("tcp_syn_linear_timeouts is 0 (disabled), risking exponential handshake stalls")
    elif syn_linear < 0:
        issues.append(f"Unable to read tcp_syn_linear_timeouts from {syn_timeouts_file}")

    if timeouts > 1000 and spurious_ratio_pct > 25.0:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated spurious RTO ratio: {spurious_ratio_pct}% (> 25.0%)")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_thin_linear_timeouts": thin_linear,
        "tcp_syn_linear_timeouts": syn_linear,
        "timeouts": timeouts,
        "spurious_rtos": spurious_rtos,
        "spurious_ratio_pct": spurious_ratio_pct,
        "loss_failures": loss_failures,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "counters": {
            "tcp_thin_linear_timeouts": thin_linear,
            "tcp_syn_linear_timeouts": syn_linear,
            "timeouts": timeouts,
            "spurious_rtos": spurious_rtos,
            "loss_failures": loss_failures,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Thin-Stream Linear Timeout & Latency Optimization Guard (Pattern 235)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_thin_timeouts()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Thin-Stream Timeout Guard (Pattern 235) - Status: {s['status']}")
    print(f"  tcp_thin_linear_timeouts:  {s['tcp_thin_linear_timeouts']} (0 = per-socket, 1 = global)")
    print(f"  tcp_syn_linear_timeouts:   {s['tcp_syn_linear_timeouts']} (linear timeouts before backoff)")
    print(f"  Total RTO Timeouts:        {s['timeouts']:,}")
    print(f"  Spurious RTOs:             {s['spurious_rtos']:,} ({s['spurious_ratio_pct']}%)")
    print(f"  Loss Recovery Failures:    {s['loss_failures']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
