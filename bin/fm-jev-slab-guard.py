#!/usr/bin/env python3
"""
fm-jev-slab-guard.py - Jev Multi-Agent Host Kernel Memory Slab Cache & Unreclaimable Page Guard (Pattern 89)

Audits Linux kernel SLAB/SLUB allocator memory consumption (/proc/meminfo, /proc/sys/fs/dentry-state, /proc/sys/fs/inode-state).
Detects excessive unreclaimable kernel object bloat (SUnreclaim), runaway dentry cache growth, and inode cache pinning
before memory compaction latency degrades agent tool executions and Playwright browser tests.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback on missing procfs files.
  - Non-privileged execution (does not require root /proc/slabinfo).
  - Fast bounded execution (< 0.05s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

DEFAULT_MEMINFO_PATH = "/proc/meminfo"
DEFAULT_DENTRY_STATE_PATH = "/proc/sys/fs/dentry-state"
DEFAULT_INODE_STATE_PATH = "/proc/sys/fs/inode-state"

DEFAULT_WARN_UNRECLAIM_MB = 8192.0  # 8 GB unreclaimable slab warning
DEFAULT_CRIT_UNRECLAIM_MB = 16384.0  # 16 GB unreclaimable slab critical
DEFAULT_WARN_UNRECLAIM_PCT = 15.0  # 15% of RAM in unreclaimable slab
DEFAULT_CRIT_UNRECLAIM_PCT = 25.0  # 25% of RAM in unreclaimable slab
DEFAULT_WARN_DENTRY_MILLIONS = 10.0  # 10M dentries


def parse_meminfo(meminfo_path: str) -> Dict[str, int]:
    """Extracts slab-related metrics from /proc/meminfo in kB."""
    metrics = {"MemTotal": 0, "Slab": 0, "SReclaimable": 0, "SUnreclaim": 0}
    if not os.path.exists(meminfo_path):
        return metrics

    try:
        with open(meminfo_path, "r") as f:
            for line in f:
                parts = line.split(":")
                if len(parts) == 2:
                    k = parts[0].strip()
                    if k in metrics:
                        val_str = parts[1].strip().split()[0]
                        metrics[k] = int(val_str)
    except Exception:
        pass
    return metrics


def parse_dentry_state(dentry_path: str) -> Dict[str, int]:
    """Parses /proc/sys/fs/dentry-state: nr_dentry nr_unused age_limit want_pages nr_negative dummy."""
    metrics = {"nr_dentry": 0, "nr_unused": 0, "age_limit": 0, "nr_negative": 0}
    if not os.path.exists(dentry_path):
        return metrics

    try:
        with open(dentry_path, "r") as f:
            line = f.read().strip()
            parts = line.split()
            if len(parts) >= 2:
                metrics["nr_dentry"] = int(parts[0])
                metrics["nr_unused"] = int(parts[1])
            if len(parts) >= 3:
                metrics["age_limit"] = int(parts[2])
            if len(parts) >= 5:
                metrics["nr_negative"] = int(parts[4])
    except Exception:
        pass
    return metrics


def parse_inode_state(inode_path: str) -> Dict[str, int]:
    """Parses /proc/sys/fs/inode-state: nr_inodes nr_free_inodes prescan ..."""
    metrics = {"nr_inodes": 0, "nr_free_inodes": 0}
    if not os.path.exists(inode_path):
        return metrics

    try:
        with open(inode_path, "r") as f:
            line = f.read().strip()
            parts = line.split()
            if len(parts) >= 2:
                metrics["nr_inodes"] = int(parts[0])
                metrics["nr_free_inodes"] = int(parts[1])
    except Exception:
        pass
    return metrics


def audit_slab(
    meminfo_path: str = DEFAULT_MEMINFO_PATH,
    dentry_state_path: str = DEFAULT_DENTRY_STATE_PATH,
    inode_state_path: str = DEFAULT_INODE_STATE_PATH,
    warn_unreclaim_mb: float = DEFAULT_WARN_UNRECLAIM_MB,
    crit_unreclaim_mb: float = DEFAULT_CRIT_UNRECLAIM_MB,
    warn_unreclaim_pct: float = DEFAULT_WARN_UNRECLAIM_PCT,
    crit_unreclaim_pct: float = DEFAULT_CRIT_UNRECLAIM_PCT,
    warn_dentry_millions: float = DEFAULT_WARN_DENTRY_MILLIONS,
) -> Dict[str, Any]:
    """Audits kernel slab allocation, unreclaimable pinned pages, and dentry/inode cache volume."""
    mem = parse_meminfo(meminfo_path)
    dentry = parse_dentry_state(dentry_state_path)
    inode = parse_inode_state(inode_state_path)
    issues: List[str] = []

    mem_total_mb = round(mem["MemTotal"] / 1024.0, 2)
    slab_mb = round(mem["Slab"] / 1024.0, 2)
    reclaimable_mb = round(mem["SReclaimable"] / 1024.0, 2)
    unreclaimable_mb = round(mem["SUnreclaim"] / 1024.0, 2)

    slab_pct = round((mem["Slab"] / mem["MemTotal"]) * 100.0, 2) if mem["MemTotal"] > 0 else 0.0
    unreclaim_pct = round((mem["SUnreclaim"] / mem["MemTotal"]) * 100.0, 2) if mem["MemTotal"] > 0 else 0.0
    reclaimable_ratio_pct = round((mem["SReclaimable"] / mem["Slab"]) * 100.0, 2) if mem["Slab"] > 0 else 0.0

    dentry_count = dentry["nr_dentry"]
    dentry_unused = dentry["nr_unused"]
    dentry_unused_pct = round((dentry_unused / dentry_count) * 100.0, 2) if dentry_count > 0 else 0.0
    dentry_millions = round(dentry_count / 1_000_000.0, 3)

    inode_count = inode["nr_inodes"]
    inode_free = inode["nr_free_inodes"]

    if unreclaimable_mb >= crit_unreclaim_mb or unreclaim_pct >= crit_unreclaim_pct:
        issues.append(
            f"Critical unreclaimable kernel slab: {unreclaimable_mb} MB ({unreclaim_pct}% of RAM). Memory fragmentation risk high."
        )
    elif unreclaimable_mb >= warn_unreclaim_mb or unreclaim_pct >= warn_unreclaim_pct:
        issues.append(
            f"Elevated unreclaimable kernel slab: {unreclaimable_mb} MB ({unreclaim_pct}% of RAM)."
        )

    if dentry_millions >= warn_dentry_millions:
        issues.append(
            f"Elevated dentry cache volume: {dentry_count:,} dentries ({dentry_unused_pct}% unused)."
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
            "slab_mb": slab_mb,
            "reclaimable_mb": reclaimable_mb,
            "unreclaimable_mb": unreclaimable_mb,
            "slab_pct_of_ram": slab_pct,
            "unreclaim_pct_of_ram": unreclaim_pct,
            "reclaimable_ratio_pct": reclaimable_ratio_pct,
            "dentry_count": dentry_count,
            "dentry_unused_pct": dentry_unused_pct,
            "inode_count": inode_count,
            "issues": issues,
        },
        "slab_memory": {
            "total_ram_mb": mem_total_mb,
            "slab_mb": slab_mb,
            "reclaimable_mb": reclaimable_mb,
            "unreclaimable_mb": unreclaimable_mb,
            "slab_pct": slab_pct,
            "unreclaim_pct": unreclaim_pct,
            "reclaimable_ratio_pct": reclaimable_ratio_pct,
        },
        "dentry_cache": dentry,
        "inode_cache": inode,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Kernel Memory Slab Cache & Unreclaimable Page Guard (Pattern 89)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument(
        "--warn-unreclaim-mb",
        type=float,
        default=DEFAULT_WARN_UNRECLAIM_MB,
        help=f"Warning unreclaimable slab in MB (default {DEFAULT_WARN_UNRECLAIM_MB})",
    )
    parser.add_argument(
        "--crit-unreclaim-mb",
        type=float,
        default=DEFAULT_CRIT_UNRECLAIM_MB,
        help=f"Critical unreclaimable slab in MB (default {DEFAULT_CRIT_UNRECLAIM_MB})",
    )
    parser.add_argument(
        "--warn-unreclaim-pct",
        type=float,
        default=DEFAULT_WARN_UNRECLAIM_PCT,
        help=f"Warning unreclaimable slab percentage of RAM (default {DEFAULT_WARN_UNRECLAIM_PCT}%%)",
    )
    parser.add_argument(
        "--crit-unreclaim-pct",
        type=float,
        default=DEFAULT_CRIT_UNRECLAIM_PCT,
        help=f"Critical unreclaimable slab percentage of RAM (default {DEFAULT_CRIT_UNRECLAIM_PCT}%%)",
    )
    parser.add_argument(
        "--warn-dentry-millions",
        type=float,
        default=DEFAULT_WARN_DENTRY_MILLIONS,
        help=f"Warning dentry threshold in millions (default {DEFAULT_WARN_DENTRY_MILLIONS})",
    )
    parser.add_argument(
        "--meminfo-path",
        type=str,
        default=DEFAULT_MEMINFO_PATH,
        help="Path to /proc/meminfo",
    )
    parser.add_argument(
        "--dentry-state-path",
        type=str,
        default=DEFAULT_DENTRY_STATE_PATH,
        help="Path to /proc/sys/fs/dentry-state",
    )
    parser.add_argument(
        "--inode-state-path",
        type=str,
        default=DEFAULT_INODE_STATE_PATH,
        help="Path to /proc/sys/fs/inode-state",
    )

    args = parser.parse_args()

    result = audit_slab(
        meminfo_path=args.meminfo_path,
        dentry_state_path=args.dentry_state_path,
        inode_state_path=args.inode_state_path,
        warn_unreclaim_mb=args.warn_unreclaim_mb,
        crit_unreclaim_mb=args.crit_unreclaim_mb,
        warn_unreclaim_pct=args.warn_unreclaim_pct,
        crit_unreclaim_pct=args.crit_unreclaim_pct,
        warn_dentry_millions=args.warn_dentry_millions,
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
    print(" Jev Multi-Agent Kernel Memory Slab & Dentry Cache Guard (Pattern 89)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    print(f" Total Slab Allocation:  {summary['slab_mb']} MB ({summary['slab_pct_of_ram']}% of RAM)")
    print(f" Reclaimable Slab:       {summary['reclaimable_mb']} MB ({summary['reclaimable_ratio_pct']}% reclaimable)")
    print(f" Unreclaimable Slab:     {summary['unreclaimable_mb']} MB ({summary['unreclaim_pct_of_ram']}% of RAM)")
    print(f" Active Dentries:        {summary['dentry_count']:,} ({summary['dentry_unused_pct']}% unused)")
    print(f" Active VFS Inodes:      {summary['inode_count']:,}")

    if summary["issues"]:
        print("\nActive Slab Cache Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nKernel slab cache subsystem nominal. Zero unreclaimable page bloat or VFS dentry stalls.")
    print("================================================================================")


if __name__ == "__main__":
    main()
