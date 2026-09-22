#!/usr/bin/env python3
"""
bin/fm-jev-tcp-metrics-guard.py - Host Network TCP Route Cache Metrics & ssthresh Guard (Pattern 168)

Audits kernel TCP route metrics caching sysctls (tcp_no_metrics_save, tcp_no_ssthresh_metrics_save)
and routing table capacity to verify optimal connection initialization parameters and eliminate
stale throttled ssthresh inheritance across repetitive multi-agent API calls.
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


def audit_tcp_metrics(
    no_metrics_save_file: str = "/proc/sys/net/ipv4/tcp_no_metrics_save",
    no_ssthresh_save_file: str = "/proc/sys/net/ipv4/tcp_no_ssthresh_metrics_save",
    low_latency_file: str = "/proc/sys/net/ipv4/tcp_low_latency",
    route_max_size_file: str = "/proc/sys/net/ipv4/route/max_size",
) -> Dict[str, Any]:
    no_metrics_save = read_sysctl_int(no_metrics_save_file)
    no_ssthresh_save = read_sysctl_int(no_ssthresh_save_file)
    low_latency = read_sysctl_int(low_latency_file)
    route_max_size = read_sysctl_int(route_max_size_file)

    issues = []
    status = "HEALTHY"
    healthy = True

    if no_ssthresh_save == 0:
        status = "WARNING"
        healthy = False
        issues.append(
            "tcp_no_ssthresh_metrics_save is disabled (0); stale throttled ssthresh may penalize new connections"
        )

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_no_metrics_save": no_metrics_save,
        "tcp_no_ssthresh_metrics_save": no_ssthresh_save,
        "tcp_low_latency": low_latency,
        "route_max_size": route_max_size,
        "metrics_caching_active": no_metrics_save == 0,
        "ssthresh_reset_active": no_ssthresh_save == 1,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_no_metrics_save": no_metrics_save,
            "tcp_no_ssthresh_metrics_save": no_ssthresh_save,
            "tcp_low_latency": low_latency,
            "route_max_size": route_max_size,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Route Cache Metrics & ssthresh Guard (Pattern 168)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_tcp_metrics()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Metrics Guard (Pattern 168) - Status: {s['status']}")
    print(f"  tcp_no_metrics_save:           {s['tcp_no_metrics_save']} (0 = cache RTT/CWND for known peers)")
    print(f"  tcp_no_ssthresh_metrics_save:  {s['tcp_no_ssthresh_metrics_save']} (1 = do NOT inherit stale ssthresh)")
    print(f"  tcp_low_latency:               {s['tcp_low_latency']}")
    print(f"  route_max_size:                {s['route_max_size']:,}")
    print(f"  Metrics Caching Active:        {s['metrics_caching_active']}")
    print(f"  ssthresh Reset Active:         {s['ssthresh_reset_active']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
