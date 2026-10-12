#!/usr/bin/env python3
"""
bin/fm-jev-calipso-guard.py - Host IPv6 CALIPSO MLS Security Label Caching & Error Guard (Pattern 254)

Audits Linux kernel RFC 5570 CALIPSO Multi-Level Security (MLS) tagging, attribute cache configuration,
and IPv6 extension header/option parsing error telemetry:
  - calipso_cache_enable: CALIPSO attribute cache status (1=enabled, 0=disabled).
    Prevents costly softirq per-packet MLS label translation overhead.
  - calipso_cache_bucket_size: Maximum bucket size for CALIPSO cache hash table (default 10).
    Bounds memory allocation and prevents hash bucket chain bloat.
  - snmp6 telemetry: Ip6InReceives, Ip6InHdrErrors, Ip6InTruncatedPkts, Ip6InDiscards.
    Detects malformed hop-by-hop extension options or packet truncation before payload delivery.

Invariants:
  - Multi-level security label translation caching is active to prevent softirq degradation.
  - Bounds cache hash chain allocation and detects malformed CALIPSO hop-by-hop extension options.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths or snmp6 are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

SYSCTL_CALIPSO_CACHE_ENABLE = "/proc/sys/net/ipv6/calipso_cache_enable"
SYSCTL_CALIPSO_BUCKET_SIZE = "/proc/sys/net/ipv6/calipso_cache_bucket_size"
PROC_SNMP6 = "/proc/net/snmp6"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0])
    except (ValueError, OSError, IndexError):
        return default


def parse_snmp6(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 2:
                    try:
                        metrics[parts[0]] = int(parts[1])
                    except ValueError:
                        pass
    except OSError:
        pass
    return metrics


def audit_calipso_guard(
    cache_enable_path: str = SYSCTL_CALIPSO_CACHE_ENABLE,
    bucket_size_path: str = SYSCTL_CALIPSO_BUCKET_SIZE,
    snmp6_path: str = PROC_SNMP6,
    warn_hdr_error_pct: float = 0.05,
    crit_hdr_error_pct: float = 0.5,
    warn_trunc_error_pct: float = 0.05,
    crit_trunc_error_pct: float = 0.5,
) -> Dict[str, Any]:
    cache_enable = read_sysctl_int(cache_enable_path, default=1)
    bucket_size = read_sysctl_int(bucket_size_path, default=10)

    snmp6_stats = parse_snmp6(snmp6_path)
    in_receives = snmp6_stats.get("Ip6InReceives", 0)
    in_hdr_errors = snmp6_stats.get("Ip6InHdrErrors", 0)
    in_trunc_pkts = snmp6_stats.get("Ip6InTruncatedPkts", 0)
    in_discards = snmp6_stats.get("Ip6InDiscards", 0)

    hdr_error_pct = (in_hdr_errors / in_receives * 100.0) if in_receives > 0 else 0.0
    trunc_error_pct = (in_trunc_pkts / in_receives * 100.0) if in_receives > 0 else 0.0

    issues: List[str] = []
    status = "HEALTHY"

    # Validate cache status
    if cache_enable == 0:
        issues.append(
            "CALIPSO attribute caching disabled (net.ipv6.calipso_cache_enable=0); "
            "per-packet MLS label parsing causes elevated softirq overhead"
        )
        status = "WARNING"
    elif cache_enable not in (0, 1):
        issues.append(f"Invalid net.ipv6.calipso_cache_enable: {cache_enable}")
        status = "WARNING"

    # Validate bucket size
    if bucket_size <= 0:
        issues.append(f"Invalid net.ipv6.calipso_cache_bucket_size: {bucket_size}")
        if status != "CRITICAL":
            status = "WARNING"
    elif bucket_size > 100:
        issues.append(
            f"Elevated net.ipv6.calipso_cache_bucket_size: {bucket_size} > 100 (excessive hash chain depth)"
        )
        if status != "CRITICAL":
            status = "WARNING"

    # Header error check
    if hdr_error_pct >= crit_hdr_error_pct:
        issues.append(
            f"Critical IPv6 header error rate: {hdr_error_pct:.4f}% "
            f"({in_hdr_errors:,} / {in_receives:,} packets)"
        )
        status = "CRITICAL"
    elif hdr_error_pct >= warn_hdr_error_pct:
        issues.append(
            f"Elevated IPv6 header error rate: {hdr_error_pct:.4f}% "
            f"({in_hdr_errors:,} / {in_receives:,} packets)"
        )
        if status != "CRITICAL":
            status = "WARNING"

    # Truncated packet check
    if trunc_error_pct >= crit_trunc_error_pct:
        issues.append(
            f"Critical IPv6 truncated packet rate: {trunc_error_pct:.4f}% "
            f"({in_trunc_pkts:,} / {in_receives:,} packets)"
        )
        status = "CRITICAL"
    elif trunc_error_pct >= warn_trunc_error_pct:
        issues.append(
            f"Elevated IPv6 truncated packet rate: {trunc_error_pct:.4f}% "
            f"({in_trunc_pkts:,} / {in_receives:,} packets)"
        )
        if status != "CRITICAL":
            status = "WARNING"

    return {
        "pattern": 254,
        "name": "calipso",
        "description": "Host IPv6 CALIPSO MLS Security Label Caching & Error Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "calipso_cache_enable": cache_enable,
        "calipso_cache_bucket_size": bucket_size,
        "in_receives": in_receives,
        "in_hdr_errors": in_hdr_errors,
        "hdr_error_ratio_pct": round(hdr_error_pct, 6),
        "in_truncated_pkts": in_trunc_pkts,
        "trunc_error_ratio_pct": round(trunc_error_pct, 6),
        "in_discards": in_discards,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Host IPv6 CALIPSO MLS Security Label Caching & Error Guard (Pattern 254)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    parser.add_argument("--cache-enable-file", default=SYSCTL_CALIPSO_CACHE_ENABLE, help="Path to calipso_cache_enable")
    parser.add_argument("--bucket-size-file", default=SYSCTL_CALIPSO_BUCKET_SIZE, help="Path to calipso_cache_bucket_size")
    parser.add_argument("--snmp6-file", default=PROC_SNMP6, help="Path to /proc/net/snmp6")
    parser.add_argument("--warn-hdr-error-pct", type=float, default=0.05, help="Warning threshold for header error percentage")
    parser.add_argument("--crit-hdr-error-pct", type=float, default=0.5, help="Critical threshold for header error percentage")
    parser.add_argument("--warn-trunc-error-pct", type=float, default=0.05, help="Warning threshold for trunc packet percentage")
    parser.add_argument("--crit-trunc-error-pct", type=float, default=0.5, help="Critical threshold for trunc packet percentage")

    args = parser.parse_args()

    report = audit_calipso_guard(
        cache_enable_path=args.cache_enable_file,
        bucket_size_path=args.bucket_size_file,
        snmp6_path=args.snmp6_file,
        warn_hdr_error_pct=args.warn_hdr_error_pct,
        crit_hdr_error_pct=args.crit_hdr_error_pct,
        warn_trunc_error_pct=args.warn_trunc_error_pct,
        crit_trunc_error_pct=args.crit_trunc_error_pct,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Pattern 254: {report['name']} - Status: {report['status']}")
        print(f"  calipso_cache_enable: {report['calipso_cache_enable']}")
        print(f"  calipso_cache_bucket_size: {report['calipso_cache_bucket_size']}")
        print(f"  in_receives: {report['in_receives']}")
        print(f"  in_hdr_errors: {report['in_hdr_errors']} ({report['hdr_error_ratio_pct']}%)")
        print(f"  in_truncated_pkts: {report['in_truncated_pkts']} ({report['trunc_error_ratio_pct']}%)")
        print(f"  in_discards: {report['in_discards']}")
        if report["issues"]:
            print("  Issues:")
            for issue in report["issues"]:
                print(f"    - {issue}")
        else:
            print("  Issues: none (nominal)")

    return 0 if report["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
