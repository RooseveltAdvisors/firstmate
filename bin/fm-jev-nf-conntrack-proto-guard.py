#!/usr/bin/env python3
"""
bin/fm-jev-nf-conntrack-proto-guard.py - Linux Netfilter Conntrack UDP, ICMP & Generic Protocol Timeouts Guard (Pattern 302 / Pattern 440)

Audits Linux kernel Netfilter connection tracking state machine timeouts for UDP, ICMP, ICMPv6,
and generic layer-4 protocols alongside connection table saturation:
  - /proc/sys/net/netfilter/nf_conntrack_udp_timeout: Unidirectional UDP state timeout in seconds (default 30s)
  - /proc/sys/net/netfilter/nf_conntrack_udp_timeout_stream: Bidirectional UDP stream timeout in seconds (default 120s)
  - /proc/sys/net/netfilter/nf_conntrack_icmp_timeout: IPv4 ICMP request/reply timeout in seconds (default 30s)
  - /proc/sys/net/netfilter/nf_conntrack_icmpv6_timeout: IPv6 ICMPv6 echo/error timeout in seconds (default 30s)
  - /proc/sys/net/netfilter/nf_conntrack_generic_timeout: Unknown/generic L4 protocol timeout in seconds (default 600s)
  - /proc/sys/net/netfilter/nf_conntrack_count: Current allocated connection tracking table entries
  - /proc/sys/net/netfilter/nf_conntrack_max: Maximum connection tracking table capacity
  - /proc/sys/net/netfilter/nf_conntrack_buckets: Hash table bucket count

Invariants:
  - udp_timeout must be within [5, 300] seconds.
  - udp_timeout_stream must be within [10, 3600] seconds.
  - udp_timeout_stream must be >= udp_timeout.
  - icmp_timeout and icmpv6_timeout must be within [5, 120] seconds.
  - generic_timeout must be within [10, 3600] seconds.
  - conntrack_count must not exceed conntrack_max (saturation_pct < 80.0% nominal).
  - Fail-open: graceful fallback when sysctl paths are restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

PROC_NETFILTER_DIR = "/proc/sys/net/netfilter"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content and (content.split()[0].lstrip("-").isdigit()) else default
    except (ValueError, OSError, IndexError):
        return default


def evaluate_nf_conntrack_proto(
    conf_dir: str = PROC_NETFILTER_DIR,
    warn_saturation_pct: float = 80.0,
    crit_saturation_pct: float = 95.0,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    udp_timeout = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_udp_timeout"), default=30)
    udp_timeout_stream = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_udp_timeout_stream"), default=120)
    icmp_timeout = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_icmp_timeout"), default=30)
    icmpv6_timeout = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_icmpv6_timeout"), default=30)
    generic_timeout = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_generic_timeout"), default=600)
    conntrack_count = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_count"), default=0)
    conntrack_max = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_max"), default=262144)
    conntrack_buckets = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_buckets"), default=262144)

    # Validate UDP timeout
    if udp_timeout != -1 and (udp_timeout < 5 or udp_timeout > 300):
        issues.append(f"Suboptimal nf_conntrack_udp_timeout ({udp_timeout}s outside nominal [5, 300]s)")
        recommendations.append("Set sysctl net.netfilter.nf_conntrack_udp_timeout=30")

    # Validate UDP stream timeout
    if udp_timeout_stream != -1 and (udp_timeout_stream < 10 or udp_timeout_stream > 3600):
        issues.append(f"Suboptimal nf_conntrack_udp_timeout_stream ({udp_timeout_stream}s outside nominal [10, 3600]s)")
        recommendations.append("Set sysctl net.netfilter.nf_conntrack_udp_timeout_stream=120")

    # Stream timeout should not be shorter than unidirectional timeout
    if udp_timeout != -1 and udp_timeout_stream != -1 and udp_timeout_stream < udp_timeout:
        issues.append(
            f"Inconsistent UDP timeouts: stream timeout ({udp_timeout_stream}s) is less than "
            f"unidirectional timeout ({udp_timeout}s)"
        )
        recommendations.append("Ensure nf_conntrack_udp_timeout_stream >= nf_conntrack_udp_timeout")

    # Validate ICMP timeouts
    if icmp_timeout != -1 and (icmp_timeout < 5 or icmp_timeout > 120):
        issues.append(f"Suboptimal nf_conntrack_icmp_timeout ({icmp_timeout}s outside nominal [5, 120]s)")
        recommendations.append("Set sysctl net.netfilter.nf_conntrack_icmp_timeout=30")

    if icmpv6_timeout != -1 and (icmpv6_timeout < 5 or icmpv6_timeout > 120):
        issues.append(f"Suboptimal nf_conntrack_icmpv6_timeout ({icmpv6_timeout}s outside nominal [5, 120]s)")
        recommendations.append("Set sysctl net.netfilter.nf_conntrack_icmpv6_timeout=30")

    # Validate generic timeout
    if generic_timeout != -1 and (generic_timeout < 10 or generic_timeout > 3600):
        issues.append(f"Suboptimal nf_conntrack_generic_timeout ({generic_timeout}s outside nominal [10, 3600]s)")
        recommendations.append("Set sysctl net.netfilter.nf_conntrack_generic_timeout=600")

    # Calculate table saturation
    saturation_pct = 0.0
    if conntrack_max > 0 and conntrack_count >= 0:
        saturation_pct = round((conntrack_count / conntrack_max) * 100.0, 4)

    bucket_ratio = 0.0
    if conntrack_buckets > 0 and conntrack_count >= 0:
        bucket_ratio = round(conntrack_count / conntrack_buckets, 4)

    if conntrack_max > 0 and conntrack_count >= 0:
        if saturation_pct >= crit_saturation_pct:
            status = "CRITICAL"
            issues.append(
                f"CRITICAL: Conntrack table near exhaustion ({conntrack_count}/{conntrack_max}, {saturation_pct}% saturation)"
            )
            recommendations.append(
                f"Increase net.netfilter.nf_conntrack_max beyond {conntrack_max} or tune protocol timeout values"
            )
        elif saturation_pct >= warn_saturation_pct:
            if status != "CRITICAL":
                status = "WARNING"
            issues.append(
                f"WARNING: Conntrack table approaching capacity ({conntrack_count}/{conntrack_max}, {saturation_pct}% saturation)"
            )
            recommendations.append("Investigate high connection churn or raise net.netfilter.nf_conntrack_max")

    if issues and status == "HEALTHY":
        status = "WARNING"

    return {
        "pattern": 302,
        "name": "nf_conntrack_proto",
        "description": "Linux Netfilter Conntrack UDP, ICMP & Generic Protocol Timeouts Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "udp_timeout_sec": udp_timeout,
        "udp_timeout_stream_sec": udp_timeout_stream,
        "icmp_timeout_sec": icmp_timeout,
        "icmpv6_timeout_sec": icmpv6_timeout,
        "generic_timeout_sec": generic_timeout,
        "conntrack_count": conntrack_count,
        "conntrack_max": conntrack_max,
        "conntrack_buckets": conntrack_buckets,
        "saturation_pct": saturation_pct,
        "bucket_ratio": bucket_ratio,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Linux Netfilter Conntrack UDP, ICMP & Generic Protocol Timeouts Guard (Pattern 302 / Pattern 440)"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--conf-dir", default=PROC_NETFILTER_DIR, help="Path to netfilter procfs directory")
    args = parser.parse_args()

    result = evaluate_nf_conntrack_proto(conf_dir=args.conf_dir)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] Pattern {result['pattern']} - {result['description']}")
        print(f"  UDP Timeout: {result['udp_timeout_sec']}s (stream: {result['udp_timeout_stream_sec']}s)")
        print(f"  ICMP Timeout: {result['icmp_timeout_sec']}s (ICMPv6: {result['icmpv6_timeout_sec']}s)")
        print(f"  Generic Timeout: {result['generic_timeout_sec']}s")
        print(f"  Table Saturation: {result['conntrack_count']}/{result['conntrack_max']} ({result['saturation_pct']}%), bucket ratio: {result['bucket_ratio']}")
        if result["issues"]:
            print("  Issues:")
            for issue in result["issues"]:
                print(f"    - {issue}")
        if result["recommendations"]:
            print("  Recommendations:")
            for rec in result["recommendations"]:
                print(f"    - {rec}")

    if not result["healthy"]:
        sys.exit(1 if result["status"] == "WARNING" else 2)


if __name__ == "__main__":
    main()
