#!/usr/bin/env python3
"""
fm-jev-conntrack-guard.py - Jev Multi-Agent Host Network Connection Tracking (Conntrack) Guard (Pattern 90)

Audits Linux netfilter connection tracking table capacity (/proc/sys/net/netfilter/nf_conntrack_count, nf_conntrack_max).
Detects conntrack table exhaustion before the kernel drops inbound/outbound packets ("nf_conntrack: table full"),
preventing connection timeouts and dropped socket streams across multi-agent RPCs, API calls, and database connections.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when conntrack is not loaded or procfs files are missing.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

PRIMARY_COUNT_PATH = "/proc/sys/net/netfilter/nf_conntrack_count"
FALLBACK_COUNT_PATH = "/proc/sys/net/ipv4/netfilter/ip_conntrack_count"
PRIMARY_MAX_PATH = "/proc/sys/net/netfilter/nf_conntrack_max"
FALLBACK_MAX_PATH = "/proc/sys/net/ipv4/netfilter/ip_conntrack_max"

DEFAULT_WARN_SATURATION_PCT = 70.0
DEFAULT_CRIT_SATURATION_PCT = 85.0


def read_int_file(path: str) -> Optional[int]:
    """Reads a single integer from a procfs file."""
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r") as f:
            return int(f.read().strip())
    except Exception:
        return None


def audit_conntrack(
    count_path: Optional[str] = None,
    max_path: Optional[str] = None,
    warn_sat_pct: float = DEFAULT_WARN_SATURATION_PCT,
    crit_sat_pct: float = DEFAULT_CRIT_SATURATION_PCT,
) -> Dict[str, Any]:
    """Audits Linux netfilter conntrack table saturation."""
    # Resolve count path
    count_file = count_path
    if count_file is None:
        if os.path.exists(PRIMARY_COUNT_PATH):
            count_file = PRIMARY_COUNT_PATH
        elif os.path.exists(FALLBACK_COUNT_PATH):
            count_file = FALLBACK_COUNT_PATH

    # Resolve max path
    max_file = max_path
    if max_file is None:
        if os.path.exists(PRIMARY_MAX_PATH):
            max_file = PRIMARY_MAX_PATH
        elif os.path.exists(FALLBACK_MAX_PATH):
            max_file = FALLBACK_MAX_PATH

    count_val = read_int_file(count_file) if count_file else None
    max_val = read_int_file(max_file) if max_file else None

    issues: List[str] = []

    # Fail-open if conntrack is not loaded on host
    if count_val is None or max_val is None:
        return {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "summary": {
                "status": "HEALTHY",
                "healthy": True,
                "conntrack_count": 0,
                "conntrack_max": 0,
                "saturation_pct": 0.0,
                "available_entries": 0,
                "conntrack_active": False,
                "issues": ["Conntrack subsystem not loaded or not in use; fail-open."],
            },
            "metrics": {
                "count_file": count_file,
                "max_file": max_file,
            },
        }

    saturation_pct = round((count_val / max_val) * 100.0, 2) if max_val > 0 else 0.0
    available_entries = max_val - count_val

    if saturation_pct >= crit_sat_pct:
        issues.append(
            f"Critical conntrack saturation: {saturation_pct}% ({count_val:,} / {max_val:,} entries). Imminent packet drop risk."
        )
    elif saturation_pct >= warn_sat_pct:
        issues.append(
            f"Elevated conntrack saturation: {saturation_pct}% ({count_val:,} / {max_val:,} entries)."
        )

    status = "HEALTHY"
    if any("Critical" in iss for iss in issues):
        status = "CRITICAL"
    elif issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "conntrack_count": count_val,
            "conntrack_max": max_val,
            "saturation_pct": saturation_pct,
            "available_entries": available_entries,
            "conntrack_active": True,
            "issues": issues,
        },
        "metrics": {
            "count_file": count_file,
            "max_file": max_file,
            "count": count_val,
            "max": max_val,
            "available": available_entries,
            "saturation_pct": saturation_pct,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network Connection Tracking (Conntrack) Guard (Pattern 90)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument(
        "--warn-saturation-pct",
        type=float,
        default=DEFAULT_WARN_SATURATION_PCT,
        help=f"Warning conntrack saturation percentage (default {DEFAULT_WARN_SATURATION_PCT}%%)",
    )
    parser.add_argument(
        "--crit-saturation-pct",
        type=float,
        default=DEFAULT_CRIT_SATURATION_PCT,
        help=f"Critical conntrack saturation percentage (default {DEFAULT_CRIT_SATURATION_PCT}%%)",
    )
    parser.add_argument(
        "--count-path",
        type=str,
        default=None,
        help="Path to nf_conntrack_count file",
    )
    parser.add_argument(
        "--max-path",
        type=str,
        default=None,
        help="Path to nf_conntrack_max file",
    )

    args = parser.parse_args()

    result = audit_conntrack(
        count_path=args.count_path,
        max_path=args.max_path,
        warn_sat_pct=args.warn_saturation_pct,
        crit_sat_pct=args.crit_saturation_pct,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = (
        "\033[32m"
        if summary["healthy"]
        else ("\033[31m" if summary["status"] == "CRITICAL" else "\033[33m")
    )
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Network Connection Tracking Guard (Pattern 90)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    if summary["conntrack_active"]:
        print(f" Tracked Connections:   {summary['conntrack_count']:,} / {summary['conntrack_max']:,} entries")
        print(f" Table Saturation:       {summary['saturation_pct']}% of limit")
        print(f" Headroom Available:     {summary['available_entries']:,} entries")
    else:
        print(" Conntrack Subsystem:    Inactive / Not Loaded (fail-open)")

    if summary["issues"]:
        print("\nActive Conntrack Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nNetfilter connection tracking table nominal. Zero packet drop risk detected.")
    print("================================================================================")


if __name__ == "__main__":
    main()
