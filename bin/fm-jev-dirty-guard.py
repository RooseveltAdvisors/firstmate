#!/usr/bin/env python3
"""
fm-jev-dirty-guard.py - Jev Multi-Agent Page Cache Writeback & Dirty Page Throttling Guard (Pattern 77)

Audits Linux kernel page cache dirty memory, background writeback thresholds, and synchronous balance_dirty_pages
throttling risk. Monitors /proc/vmstat, /proc/meminfo, and /proc/sys/vm/dirty_* to prevent synchronous I/O
blocking freezes during heavy multi-agent build/test runs, database logging, and git operations.

Invariants:
  - Read-only diagnostics. Non-destructive.
  - Fail-open: graceful fallback on systems with non-standard procfs.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

DEFAULT_WARN_DIRTY_SAT_PCT = 70.0
DEFAULT_CRIT_DIRTY_SAT_PCT = 90.0
DEFAULT_WARN_DIRTY_MB = 2048.0   # 2 GB
DEFAULT_CRIT_DIRTY_MB = 5120.0   # 5 GB

PROC_VMSTAT = "/proc/vmstat"
PROC_MEMINFO = "/proc/meminfo"
SYS_DIRTY_RATIO = "/proc/sys/vm/dirty_ratio"
SYS_DIRTY_BG_RATIO = "/proc/sys/vm/dirty_background_ratio"
SYS_DIRTY_EXPIRE = "/proc/sys/vm/dirty_expire_centisecs"
SYS_DIRTY_WB = "/proc/sys/vm/dirty_writeback_centisecs"
PAGE_SIZE = os.sysconf("SC_PAGE_SIZE") if hasattr(os, "sysconf") else 4096


def read_sysctl_int(path: str, default: int = 0) -> int:
    """Reads integer sysctl."""
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r") as f:
            return int(f.read().strip())
    except Exception:
        return default


def parse_vmstat(path: str = PROC_VMSTAT) -> Dict[str, int]:
    """Parses /proc/vmstat key-value counters."""
    counters: Dict[str, int] = {}
    if not os.path.exists(path):
        return counters
    try:
        with open(path, "r") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2:
                    try:
                        counters[parts[0]] = int(parts[1])
                    except ValueError:
                        pass
    except Exception:
        pass
    return counters


def parse_meminfo(path: str = PROC_MEMINFO) -> Dict[str, int]:
    """Parses /proc/meminfo into kB dictionary."""
    mem: Dict[str, int] = {}
    if not os.path.exists(path):
        return mem
    try:
        with open(path, "r") as f:
            for line in f:
                parts = line.split(":")
                if len(parts) >= 2:
                    k = parts[0].strip()
                    v = parts[1].strip().split()[0]
                    try:
                        mem[k] = int(v)
                    except ValueError:
                        pass
    except Exception:
        pass
    return mem


def audit_dirty_pages(
    vmstat_path: str = PROC_VMSTAT,
    meminfo_path: str = PROC_MEMINFO,
    dirty_ratio_path: str = SYS_DIRTY_RATIO,
    dirty_bg_ratio_path: str = SYS_DIRTY_BG_RATIO,
    dirty_expire_path: str = SYS_DIRTY_EXPIRE,
    dirty_wb_path: str = SYS_DIRTY_WB,
    warn_sat_pct: float = DEFAULT_WARN_DIRTY_SAT_PCT,
    crit_sat_pct: float = DEFAULT_CRIT_DIRTY_SAT_PCT,
    warn_dirty_mb: float = DEFAULT_WARN_DIRTY_MB,
    crit_dirty_mb: float = DEFAULT_CRIT_DIRTY_MB,
) -> Dict[str, Any]:
    """Audits dirty page counters and writeback thresholds."""
    vm = parse_vmstat(vmstat_path)
    mem = parse_meminfo(meminfo_path)

    dirty_ratio = read_sysctl_int(dirty_ratio_path, default=20)
    dirty_bg_ratio = read_sysctl_int(dirty_bg_ratio_path, default=10)
    dirty_expire = read_sysctl_int(dirty_expire_path, default=3000)
    dirty_wb = read_sysctl_int(dirty_wb_path, default=500)

    nr_dirty = vm.get("nr_dirty", 0)
    nr_writeback = vm.get("nr_writeback", 0)
    nr_dirty_threshold = vm.get("nr_dirty_threshold", 0)
    nr_dirty_bg_threshold = vm.get("nr_dirty_background_threshold", 0)

    # Byte and MB conversions
    dirty_bytes = nr_dirty * PAGE_SIZE
    dirty_mb = round(dirty_bytes / (1024.0 * 1024.0), 2)
    writeback_bytes = nr_writeback * PAGE_SIZE
    writeback_mb = round(writeback_bytes / (1024.0 * 1024.0), 2)

    threshold_mb = round((nr_dirty_threshold * PAGE_SIZE) / (1024.0 * 1024.0), 2) if nr_dirty_threshold > 0 else None
    bg_threshold_mb = round((nr_dirty_bg_threshold * PAGE_SIZE) / (1024.0 * 1024.0), 2) if nr_dirty_bg_threshold > 0 else None

    # Saturation percentage against hard threshold
    dirty_sat_pct = 0.0
    if nr_dirty_threshold > 0:
        dirty_sat_pct = round((nr_dirty / nr_dirty_threshold) * 100.0, 2)
    elif "MemTotal" in mem and mem["MemTotal"] > 0:
        # Fallback to dirty_ratio of MemTotal
        est_threshold_kb = (mem["MemTotal"] * dirty_ratio) / 100.0
        if est_threshold_kb > 0:
            dirty_sat_pct = round(((dirty_bytes / 1024.0) / est_threshold_kb) * 100.0, 2)

    bg_sat_pct = 0.0
    if nr_dirty_bg_threshold > 0:
        bg_sat_pct = round((nr_dirty / nr_dirty_bg_threshold) * 100.0, 2)

    # Health assessment
    issues: List[str] = []
    status = "HEALTHY"

    if dirty_sat_pct >= crit_sat_pct or dirty_mb >= crit_dirty_mb:
        status = "CRITICAL"
        if dirty_sat_pct >= crit_sat_pct:
            issues.append(f"Dirty page saturation critical: {dirty_sat_pct}% of throttling threshold (synchronous stall risk)")
        if dirty_mb >= crit_dirty_mb:
            issues.append(f"Dirty page volume critical: {dirty_mb} MB")
    elif dirty_sat_pct >= warn_sat_pct or dirty_mb >= warn_dirty_mb:
        status = "WARNING"
        if dirty_sat_pct >= warn_sat_pct:
            issues.append(f"Dirty page saturation elevated: {dirty_sat_pct}% of throttling threshold")
        if dirty_mb >= warn_dirty_mb:
            issues.append(f"Dirty page volume elevated: {dirty_mb} MB")

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "dirty_pages": nr_dirty,
            "dirty_mb": dirty_mb,
            "writeback_pages": nr_writeback,
            "writeback_mb": writeback_mb,
            "dirty_saturation_pct": dirty_sat_pct,
            "background_saturation_pct": bg_sat_pct,
            "dirty_threshold_mb": threshold_mb,
            "background_threshold_mb": bg_threshold_mb,
            "issues": issues,
        },
        "sysctl": {
            "dirty_ratio": dirty_ratio,
            "dirty_background_ratio": dirty_bg_ratio,
            "dirty_expire_centisecs": dirty_expire,
            "dirty_writeback_centisecs": dirty_wb,
        },
        "meminfo_kb": {
            "Dirty": mem.get("Dirty", 0),
            "Writeback": mem.get("Writeback", 0),
            "MemAvailable": mem.get("MemAvailable", 0),
            "MemTotal": mem.get("MemTotal", 0),
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Page Cache Writeback & Dirty Page Throttling Guard (Pattern 77)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--warn-sat", type=float, default=DEFAULT_WARN_DIRTY_SAT_PCT, help=f"Warning dirty saturation pct (default {DEFAULT_WARN_DIRTY_SAT_PCT})")
    parser.add_argument("--crit-sat", type=float, default=DEFAULT_CRIT_DIRTY_SAT_PCT, help=f"Critical dirty saturation pct (default {DEFAULT_CRIT_DIRTY_SAT_PCT})")
    parser.add_argument("--warn-mb", type=float, default=DEFAULT_WARN_DIRTY_MB, help=f"Warning dirty MB (default {DEFAULT_WARN_DIRTY_MB})")
    parser.add_argument("--crit-mb", type=float, default=DEFAULT_CRIT_DIRTY_MB, help=f"Critical dirty MB (default {DEFAULT_CRIT_DIRTY_MB})")
    parser.add_argument("--proc-vmstat", type=str, default=PROC_VMSTAT, help="Path to /proc/vmstat")
    parser.add_argument("--proc-meminfo", type=str, default=PROC_MEMINFO, help="Path to /proc/meminfo")
    parser.add_argument("--sysctl-dirty-ratio", type=str, default=SYS_DIRTY_RATIO, help="Path to dirty_ratio sysctl")
    parser.add_argument("--sysctl-dirty-bg-ratio", type=str, default=SYS_DIRTY_BG_RATIO, help="Path to dirty_background_ratio sysctl")

    args = parser.parse_args()

    result = audit_dirty_pages(
        vmstat_path=args.proc_vmstat,
        meminfo_path=args.proc_meminfo,
        dirty_ratio_path=args.sysctl_dirty_ratio,
        dirty_bg_ratio_path=args.sysctl_dirty_bg_ratio,
        warn_sat_pct=args.warn_sat,
        crit_sat_pct=args.crit_sat,
        warn_dirty_mb=args.warn_mb,
        crit_dirty_mb=args.crit_mb,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else ("\033[31m" if summary["status"] == "CRITICAL" else "\033[33m")
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Page Cache Writeback & Dirty Page Guard (Pattern 77)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    print(f" Dirty Page Volume:      {summary['dirty_mb']} MB ({summary['dirty_pages']} pages)")
    thresh_str = f" / {summary['dirty_threshold_mb']} MB" if summary['dirty_threshold_mb'] is not None else ""
    print(f" Dirty Saturation:       {summary['dirty_saturation_pct']}%{thresh_str}")
    bg_thresh_str = f" / {summary['background_threshold_mb']} MB" if summary['background_threshold_mb'] is not None else ""
    print(f" Background Saturation:  {summary['background_saturation_pct']}%{bg_thresh_str}")
    print(f" Active Writeback:       {summary['writeback_mb']} MB ({summary['writeback_pages']} pages in flight)")
    print(f" Kernel Ratios:          dirty_ratio={result['sysctl']['dirty_ratio']}%, dirty_background_ratio={result['sysctl']['dirty_background_ratio']}%")

    if summary["issues"]:
        print("\nActive Issues:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nNo synchronous balance_dirty_pages throttling or writeback congestion detected.")
    print("================================================================================")


if __name__ == "__main__":
    main()
