#!/usr/bin/env python3
"""
bin/fm-jev-vm-watermark-guard.py - Host Kernel VM Watermarks & Direct Reclaim Stall Guard (Pattern 201)

Audits Linux kernel virtual memory reclaim watermarks and foreground allocation stall counters:
  - /proc/sys/vm/min_free_kbytes (WMARK_MIN baseline)
  - /proc/sys/vm/watermark_scale_factor (gap between min, low, high watermarks)
  - /proc/sys/vm/watermark_boost_factor (temporary watermark boost during high-order fragmentation)
  - /proc/sys/vm/vfs_cache_pressure (dentry/inode reclaim preference)
  - /proc/sys/vm/swappiness (anon vs file-backed reclaim balance)
  - /proc/vmstat: pgscan_kswapd, pgscan_direct, pgscan_direct_throttle, allocstall_normal, allocstall_movable, pageoutrun

Quantifies foreground vs background page reclaim efficiency:
  - direct_reclaim_ratio_pct = pgscan_direct / (pgscan_kswapd + pgscan_direct) * 100
  - total_alloc_stalls = sum(allocstall_*)

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysfs/procfs files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Tuple


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception:
        return default


def parse_vmstat(path: str = "/proc/vmstat") -> Dict[str, int]:
    counters: Dict[str, int] = {}
    if not os.path.exists(path):
        return counters
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) == 2:
                    try:
                        counters[parts[0]] = int(parts[1])
                    except ValueError:
                        continue
    except Exception:
        pass
    return counters


def audit_vm_watermarks(
    proc_sys_vm: str = "/proc/sys/vm",
    proc_vmstat: str = "/proc/vmstat",
    warn_direct_reclaim_pct: float = 35.0,
) -> Dict[str, Any]:
    min_free_kb = read_sysctl_int(os.path.join(proc_sys_vm, "min_free_kbytes"), 67584)
    wm_scale_factor = read_sysctl_int(os.path.join(proc_sys_vm, "watermark_scale_factor"), 10)
    wm_boost_factor = read_sysctl_int(os.path.join(proc_sys_vm, "watermark_boost_factor"), 15000)
    vfs_cache_pressure = read_sysctl_int(os.path.join(proc_sys_vm, "vfs_cache_pressure"), 100)
    swappiness = read_sysctl_int(os.path.join(proc_sys_vm, "swappiness"), 60)

    vmstat = parse_vmstat(proc_vmstat)

    pgscan_kswapd = vmstat.get("pgscan_kswapd", 0)
    pgscan_direct = vmstat.get("pgscan_direct", 0)
    pgscan_direct_throttle = vmstat.get("pgscan_direct_throttle", 0)
    pageoutrun = vmstat.get("pageoutrun", 0)

    allocstall_dma = vmstat.get("allocstall_dma", 0)
    allocstall_dma32 = vmstat.get("allocstall_dma32", 0)
    allocstall_normal = vmstat.get("allocstall_normal", 0)
    allocstall_movable = vmstat.get("allocstall_movable", 0)
    total_alloc_stalls = allocstall_dma + allocstall_dma32 + allocstall_normal + allocstall_movable

    total_scanned = pgscan_kswapd + pgscan_direct
    direct_reclaim_pct = round((pgscan_direct / total_scanned * 100.0), 2) if total_scanned > 0 else 0.0

    issues: List[str] = []
    if pgscan_direct_throttle > 0:
        issues.append(f"CRITICAL: direct reclaim throttling active ({pgscan_direct_throttle} events)")
    if direct_reclaim_pct >= warn_direct_reclaim_pct:
        issues.append(f"WARNING: elevated direct reclaim ratio ({direct_reclaim_pct}% >= {warn_direct_reclaim_pct}%)")

    status = "CRITICAL" if pgscan_direct_throttle > 0 else ("WARNING" if issues else "HEALTHY")

    summary = {
        "status": status,
        "healthy": (status == "HEALTHY"),
        "min_free_kbytes": min_free_kb,
        "watermark_scale_factor": wm_scale_factor,
        "watermark_boost_factor": wm_boost_factor,
        "vfs_cache_pressure": vfs_cache_pressure,
        "swappiness": swappiness,
        "pgscan_kswapd": pgscan_kswapd,
        "pgscan_direct": pgscan_direct,
        "pgscan_direct_throttle": pgscan_direct_throttle,
        "direct_reclaim_ratio_pct": direct_reclaim_pct,
        "total_alloc_stalls": total_alloc_stalls,
        "allocstall_normal": allocstall_normal,
        "allocstall_movable": allocstall_movable,
        "pageoutrun": pageoutrun,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Kernel VM Watermarks & Direct Reclaim Stall Guard (Pattern 201)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    parser.add_argument(
        "--warn-direct-pct",
        type=float,
        default=35.0,
        help="Warning threshold for direct reclaim ratio percentage (default: 35.0)",
    )
    args = parser.parse_args()

    report = audit_vm_watermarks(warn_direct_reclaim_pct=args.warn_direct_pct)

    if args.json:
        print(json.dumps(report, indent=2))
        return 0 if report["summary"]["healthy"] else 1

    s = report["summary"]
    print(f"Kernel VM Watermarks & Direct Reclaim Stall Guard (Pattern 201)")
    print(f"  Status:                  {s['status']}")
    print(f"  min_free_kbytes:         {s['min_free_kbytes']} KB")
    print(f"  watermark_scale_factor:  {s['watermark_scale_factor']} ({s['watermark_scale_factor'] / 1000.0 * 100:.1f}% of zone)")
    print(f"  watermark_boost_factor:  {s['watermark_boost_factor']}")
    print(f"  vfs_cache_pressure:      {s['vfs_cache_pressure']}")
    print(f"  swappiness:              {s['swappiness']}")
    print(f"  Direct Reclaim Ratio:    {s['direct_reclaim_ratio_pct']}% ({s['pgscan_direct']:,} direct / {s['pgscan_kswapd']:,} kswapd)")
    print(f"  Direct Reclaim Throttle: {s['pgscan_direct_throttle']} events")
    print(f"  Total Allocation Stalls: {s['total_alloc_stalls']:,} (Normal: {s['allocstall_normal']:,}, Movable: {s['allocstall_movable']:,})")
    print(f"  kswapd Wakeups:          {s['pageoutrun']:,}")

    if s["issues"]:
        print("\nIdentified Issues:")
        for iss in s["issues"]:
            print(f"  - {iss}")

    return 0 if s["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
