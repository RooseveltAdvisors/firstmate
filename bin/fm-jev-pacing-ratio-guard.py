#!/usr/bin/env python3
"""
bin/fm-jev-pacing-ratio-guard.py - Host Network TCP Packet Pacing Ratios & Unsent Low-Water Mark Guard (Pattern 186)

Audits kernel TCP packet pacing ratios during congestion avoidance (tcp_pacing_ca_ratio) and
slow start (tcp_pacing_ss_ratio), socket unsent low-water mark (tcp_notsent_lowat), and auto-corking
state (tcp_autocorking) alongside coalesced corking and write queue overflow counters in /proc/net/netstat.
Ensures smooth packet transmission shaping, eliminates burst-induced microbursts on local NIC queues,
and prevents excessive write-queue buffering across high-throughput multi-agent artifact streaming.
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


def audit_pacing_ratio(
    ca_ratio_file: str = "/proc/sys/net/ipv4/tcp_pacing_ca_ratio",
    ss_ratio_file: str = "/proc/sys/net/ipv4/tcp_pacing_ss_ratio",
    notsent_file: str = "/proc/sys/net/ipv4/tcp_notsent_lowat",
    autocork_file: str = "/proc/sys/net/ipv4/tcp_autocorking",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    ca_ratio = read_sysctl_int(ca_ratio_file)
    ss_ratio = read_sysctl_int(ss_ratio_file)
    notsent_lowat = read_sysctl_int(notsent_file)
    autocorking = read_sysctl_int(autocork_file)

    netstat = parse_netstat(netstat_file)

    autocork_count = netstat.get("TCPAutoCorking", 0)
    wqueue_too_big = netstat.get("TCPWqueueTooBig", 0)
    delivered = netstat.get("TCPDelivered", 0)
    ack_compressed = netstat.get("TCPAckCompressed", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    if ca_ratio == -1:
        status = "WARNING"
        healthy = False
        issues.append("Unable to read net.ipv4.tcp_pacing_ca_ratio sysctl")
    elif ca_ratio < 100:
        status = "WARNING"
        healthy = False
        issues.append(f"Congestion avoidance pacing ratio is sub-optimal: {ca_ratio}% (< 100% causes throughput degradation)")
    elif ca_ratio > 300:
        status = "WARNING"
        healthy = False
        issues.append(f"Congestion avoidance pacing ratio is excessively high: {ca_ratio}% (> 300% causes queue packet bursts)")

    if ss_ratio == -1:
        status = "WARNING"
        healthy = False
        issues.append("Unable to read net.ipv4.tcp_pacing_ss_ratio sysctl")
    elif ss_ratio < 100:
        status = "WARNING"
        healthy = False
        issues.append(f"Slow start pacing ratio is sub-optimal: {ss_ratio}% (< 100% starves line-rate convergence)")
    elif ss_ratio > 400:
        status = "WARNING"
        healthy = False
        issues.append(f"Slow start pacing ratio is excessively high: {ss_ratio}% (> 400% causes switch buffer overruns)")

    if autocorking == 0:
        status = "WARNING"
        healthy = False
        issues.append("TCP autocorking is disabled (0), increasing small packet interrupt overhead")

    if wqueue_too_big > 100:
        status = "WARNING"
        healthy = False
        issues.append(f"High TCP write queue overflow events detected: {wqueue_too_big}")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_pacing_ca_ratio": ca_ratio,
        "tcp_pacing_ss_ratio": ss_ratio,
        "tcp_notsent_lowat": notsent_lowat,
        "tcp_autocorking": autocorking,
        "autocork_count": autocork_count,
        "wqueue_too_big": wqueue_too_big,
        "delivered": delivered,
        "ack_compressed": ack_compressed,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_pacing_ca_ratio": ca_ratio,
            "tcp_pacing_ss_ratio": ss_ratio,
            "tcp_notsent_lowat": notsent_lowat,
            "tcp_autocorking": autocorking,
        },
        "counters": {
            "TCPAutoCorking": autocork_count,
            "TCPWqueueTooBig": wqueue_too_big,
            "TCPDelivered": delivered,
            "TCPAckCompressed": ack_compressed,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Packet Pacing Ratios & Unsent Low-Water Mark Guard (Pattern 186)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_pacing_ratio()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Packet Pacing Ratios Guard (Pattern 186) - Status: {s['status']}")
    print(f"  tcp_pacing_ca_ratio:    {s['tcp_pacing_ca_ratio']}% (Congestion Avoidance)")
    print(f"  tcp_pacing_ss_ratio:    {s['tcp_pacing_ss_ratio']}% (Slow Start)")
    print(f"  tcp_notsent_lowat:      {s['tcp_notsent_lowat']} bytes")
    print(f"  tcp_autocorking:        {s['tcp_autocorking']} (1 = enabled)")
    print(f"  Auto-Corked Packets:    {s['autocork_count']}")
    print(f"  Write Queue Overflows:  {s['wqueue_too_big']}")
    print(f"  Total Delivered Segs:   {s['delivered']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
