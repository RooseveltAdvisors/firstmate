#!/usr/bin/env python3
"""
bin/fm-jev-tsq-pacing-guard.py - Host Network TCP Small Queues (TSQ) & Rate Pacing Guard (Pattern 167)

Audits kernel TCP Small Queues output byte limits (tcp_limit_output_bytes) and fair queueing rate
pacing ratios (tcp_pacing_ss_ratio, tcp_pacing_ca_ratio) alongside segmentation divisors and host
queue retransmission counters to verify smoothly paced micro-burst delivery and eliminate network
driver ring bufferbloat across high-throughput agent token streams.
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


def audit_tsq_pacing(
    limit_output_bytes_file: str = "/proc/sys/net/ipv4/tcp_limit_output_bytes",
    pacing_ss_file: str = "/proc/sys/net/ipv4/tcp_pacing_ss_ratio",
    pacing_ca_file: str = "/proc/sys/net/ipv4/tcp_pacing_ca_ratio",
    tso_win_divisor_file: str = "/proc/sys/net/ipv4/tcp_tso_win_divisor",
    min_tso_segs_file: str = "/proc/sys/net/ipv4/tcp_min_tso_segs",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    limit_output_bytes = read_sysctl_int(limit_output_bytes_file)
    pacing_ss = read_sysctl_int(pacing_ss_file)
    pacing_ca = read_sysctl_int(pacing_ca_file)
    tso_win_divisor = read_sysctl_int(tso_win_divisor_file)
    min_tso_segs = read_sysctl_int(min_tso_segs_file)
    netstat = parse_netstat(netstat_file)

    autocorking = netstat.get("TCPAutoCorking", 0)
    spurious_host_queues = netstat.get("TCPSpuriousRtxHostQueues", 0)
    delivered = netstat.get("TCPDelivered", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    if limit_output_bytes > 0 and limit_output_bytes < 32768:
        status = "WARNING"
        healthy = False
        issues.append(f"Suboptimal tcp_limit_output_bytes ({limit_output_bytes} B), risk of TSQ pipeline starvation")
    elif limit_output_bytes > 33554432:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated tcp_limit_output_bytes ({limit_output_bytes} B), risk of driver bufferbloat")

    if pacing_ca < 100 and pacing_ca > 0:
        status = "WARNING"
        healthy = False
        issues.append(f"tcp_pacing_ca_ratio ({pacing_ca}) under 100%, causing artificial throughput throttling")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_limit_output_bytes": limit_output_bytes,
        "limit_output_mb": round(limit_output_bytes / (1024 * 1024), 2) if limit_output_bytes > 0 else -1,
        "tcp_pacing_ss_ratio": pacing_ss,
        "tcp_pacing_ca_ratio": pacing_ca,
        "tcp_tso_win_divisor": tso_win_divisor,
        "tcp_min_tso_segs": min_tso_segs,
        "autocorking_events": autocorking,
        "spurious_host_queues": spurious_host_queues,
        "delivered_segments": delivered,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_limit_output_bytes": limit_output_bytes,
            "tcp_pacing_ss_ratio": pacing_ss,
            "tcp_pacing_ca_ratio": pacing_ca,
            "tcp_tso_win_divisor": tso_win_divisor,
            "tcp_min_tso_segs": min_tso_segs,
        },
        "counters": {
            "TCPAutoCorking": autocorking,
            "TCPSpuriousRtxHostQueues": spurious_host_queues,
            "TCPDelivered": delivered,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Small Queues (TSQ) & Rate Pacing Guard (Pattern 167)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_tsq_pacing()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP TSQ Pacing Guard (Pattern 167) - Status: {s['status']}")
    print(f"  tcp_limit_output_bytes:    {s['tcp_limit_output_bytes']:,} B ({s['limit_output_mb']} MiB TSQ limit)")
    print(f"  tcp_pacing_ss_ratio:       {s['tcp_pacing_ss_ratio']}% (slow-start pacing rate)")
    print(f"  tcp_pacing_ca_ratio:       {s['tcp_pacing_ca_ratio']}% (congestion avoidance pacing rate)")
    print(f"  tcp_tso_win_divisor:       {s['tcp_tso_win_divisor']}")
    print(f"  tcp_min_tso_segs:          {s['tcp_min_tso_segs']}")
    print(f"  Auto-Corking Events:       {s['autocorking_events']:,}")
    print(f"  Spurious Host Queue Rtx:   {s['spurious_host_queues']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
