#!/usr/bin/env python3
"""
fm-jev-thp-guard.py - Jev Multi-Agent Transparent Huge Pages (THP) & Compaction Stall Guard (Pattern 64)

Audits Linux kernel Transparent Huge Pages (THP) metrics and memory compaction stalls via:
  - /sys/kernel/mm/transparent_hugepage/enabled
  - /sys/kernel/mm/transparent_hugepage/defrag
  - /proc/vmstat (compact_stall, compact_fail, compact_success, thp_fault_alloc, thp_fault_fallback)

Detects kernel memory compaction latency spikes that freeze LLM inference (vLLM, Ollama)
and multi-agent worker processes during memory allocation.

Invariants:
  - Read-only diagnostics by default. Non-destructive.
  - Fail-open: graceful handling on virtualized or non-standard kernel sysfs.
  - Bounded fast execution (< 0.1s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple


DEFAULT_WARN_COMPACT_FAIL_RATIO = 0.85
DEFAULT_WARN_THP_FALLBACK_RATIO = 0.50


def read_sysfs_option(path: str) -> str:
    """Reads a sysfs bracketed choice file like '[always] madvise never'."""
    try:
        with open(path, "r", errors="replace") as f:
            content = f.read().strip()
            # Extract bracketed option
            for part in content.split():
                if part.startswith("[") and part.endswith("]"):
                    return part.strip("[]")
            return content
    except Exception:
        return "unknown"


def read_vmstat_counters(vmstat_path: str = "/proc/vmstat") -> Dict[str, int]:
    """Reads memory compaction and THP counters from /proc/vmstat."""
    counters: Dict[str, int] = {}
    interesting_keys = {
        "compact_stall",
        "compact_fail",
        "compact_success",
        "compact_isolated",
        "compact_daemon_wake",
        "thp_fault_alloc",
        "thp_fault_fallback",
        "thp_collapse_alloc",
        "thp_collapse_alloc_failed",
        "thp_split_page",
        "thp_split_page_failed",
        "thp_deferred_split_page",
        "thp_zero_page_alloc",
    }
    try:
        with open(vmstat_path, "r", errors="replace") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 2 and parts[0] in interesting_keys:
                    try:
                        counters[parts[0]] = int(parts[1])
                    except ValueError:
                        pass
    except Exception:
        pass
    return counters


def audit_fleet_thp(
    sysfs_root: str = "/sys/kernel/mm/transparent_hugepage",
    vmstat_path: str = "/proc/vmstat",
    warn_compact_fail_ratio: float = DEFAULT_WARN_COMPACT_FAIL_RATIO,
    warn_thp_fallback_ratio: float = DEFAULT_WARN_THP_FALLBACK_RATIO,
) -> Dict[str, Any]:
    """Audits Transparent Huge Pages configuration and compaction stall metrics."""
    enabled_path = os.path.join(sysfs_root, "enabled")
    defrag_path = os.path.join(sysfs_root, "defrag")

    thp_enabled = read_sysfs_option(enabled_path)
    thp_defrag = read_sysfs_option(defrag_path)

    counters = read_vmstat_counters(vmstat_path)

    compact_stall = counters.get("compact_stall", 0)
    compact_fail = counters.get("compact_fail", 0)
    compact_success = counters.get("compact_success", 0)
    total_compact = compact_fail + compact_success
    compact_fail_ratio = (compact_fail / total_compact) if total_compact > 0 else 0.0

    thp_alloc = counters.get("thp_fault_alloc", 0)
    thp_fallback = counters.get("thp_fault_fallback", 0)
    total_thp_attempts = thp_alloc + thp_fallback
    thp_fallback_ratio = (thp_fallback / total_thp_attempts) if total_thp_attempts > 0 else 0.0

    flagged_reasons: List[str] = []
    status = "HEALTHY"

    # Evaluate THP mode
    if thp_enabled == "always" and thp_defrag == "always":
        flagged_reasons.append("Synchronous direct compaction active (enabled=always, defrag=always); risk of thread stall spikes")
        status = "WARNING"

    if total_compact > 1000 and compact_fail_ratio >= warn_compact_fail_ratio and compact_stall > 100000:
        flagged_reasons.append(
            f"High compaction failure ratio ({compact_fail_ratio * 100:.1f}%, {compact_fail}/{total_compact}) with {compact_stall} compaction stalls"
        )
        status = "WARNING"

    if total_thp_attempts > 1000 and thp_fallback_ratio >= warn_thp_fallback_ratio:
        flagged_reasons.append(
            f"High THP allocation fallback ratio ({thp_fallback_ratio * 100:.1f}%, {thp_fallback}/{total_thp_attempts})"
        )
        if status != "CRITICAL":
            status = "WARNING"

    recommendation = "; ".join(flagged_reasons) if flagged_reasons else "optimal"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "thp_enabled": thp_enabled,
            "thp_defrag": thp_defrag,
            "compact_stall_count": compact_stall,
            "compact_fail_count": compact_fail,
            "compact_success_count": compact_success,
            "compact_fail_ratio": round(compact_fail_ratio, 4),
            "thp_fault_alloc_count": thp_alloc,
            "thp_fault_fallback_count": thp_fallback,
            "thp_fallback_ratio": round(thp_fallback_ratio, 4),
            "warn_compact_fail_ratio": warn_compact_fail_ratio,
            "warn_thp_fallback_ratio": warn_thp_fallback_ratio,
            "status": status,
            "recommendation": recommendation,
            "healthy": (status == "HEALTHY"),
        },
        "raw_counters": counters,
        "flagged_reasons": flagged_reasons,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Transparent Huge Pages (THP) & Compaction Stall Guard (Pattern 64)"
    )
    parser.add_argument(
        "--warn-compact-fail-ratio",
        type=float,
        default=DEFAULT_WARN_COMPACT_FAIL_RATIO,
        help=f"Warn threshold for compaction failure ratio (default: {DEFAULT_WARN_COMPACT_FAIL_RATIO})",
    )
    parser.add_argument(
        "--warn-thp-fallback-ratio",
        type=float,
        default=DEFAULT_WARN_THP_FALLBACK_RATIO,
        help=f"Warn threshold for THP fallback ratio (default: {DEFAULT_WARN_THP_FALLBACK_RATIO})",
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--verbose", action="store_true", help="Verbose metrics listing")

    args = parser.parse_args()

    report = audit_fleet_thp(
        warn_compact_fail_ratio=args.warn_compact_fail_ratio,
        warn_thp_fallback_ratio=args.warn_thp_fallback_ratio,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        summary = report["summary"]
        status_str = summary["status"]
        print(f"[{status_str}] Jev Transparent Huge Pages & Compaction Guard (Pattern 64)")
        print(f"THP Enabled: {summary['thp_enabled']} | Defrag: {summary['thp_defrag']}")
        print(f"Compaction Stalls: {summary['compact_stall_count']:,} (Fail Ratio: {summary['compact_fail_ratio'] * 100:.1f}%)")
        print(f"THP Allocations: {summary['thp_fault_alloc_count']:,} | Fallbacks: {summary['thp_fault_fallback_count']:,} ({summary['thp_fallback_ratio'] * 100:.1f}%)")
        print(f"Health Status: {summary['status']}")
        print(f"Recommendation: {summary['recommendation']}")

        if args.verbose and report["raw_counters"]:
            print("\nRaw VMStat Counters:")
            for k, v in sorted(report["raw_counters"].items()):
                print(f"  {k:<28}: {v:,}")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
