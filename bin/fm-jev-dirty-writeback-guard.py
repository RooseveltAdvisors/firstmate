#!/usr/bin/env python3
"""
fm-jev-dirty-writeback-guard.py - Jev Multi-Agent Host Kernel Dirty Memory Page Writeback & Throttling Stall Guard (Pattern 88)

Audits Linux kernel memory subsystem dirty page accumulators (/proc/vmstat) and writeback thresholds.
Detects when unwritten filesystem cache dirty pages approach dirty_threshold or dirty_background_threshold,
triggering synchronous kernel writeback throttling (balance_dirty_pages) which stalls agent test runners,
git operations, and database writes in uninterruptible D-state sleeps.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback on missing vmstat.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import glob
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

DEFAULT_VMSTAT_PATH = "/proc/vmstat"
DEFAULT_PROC_DIR = "/proc"
DEFAULT_SYSCTL_DIR = "/proc/sys/vm"
DEFAULT_WARN_SATURATION_PCT = 70.0
DEFAULT_CRIT_SATURATION_PCT = 90.0
PAGE_SIZE_KB = 4  # Standard Linux 4KB memory page


def audit_dirty_writeback(
    vmstat_path: str = DEFAULT_VMSTAT_PATH,
    proc_dir: str = DEFAULT_PROC_DIR,
    sysctl_dir: str = DEFAULT_SYSCTL_DIR,
    warn_sat_pct: float = DEFAULT_WARN_SATURATION_PCT,
    crit_sat_pct: float = DEFAULT_CRIT_SATURATION_PCT,
) -> Dict[str, Any]:
    """Audits kernel dirty pages and writeback pressure against throttling thresholds."""
    nr_dirty = 0
    nr_writeback = 0
    nr_dirty_threshold = 0
    nr_dirty_bg_threshold = 0
    issues: List[str] = []

    if not os.path.exists(vmstat_path):
        return {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "summary": {
                "status": "HEALTHY",
                "healthy": True,
                "nr_dirty_pages": 0,
                "nr_writeback_pages": 0,
                "dirty_mb": 0.0,
                "saturation_pct": 0.0,
                "d_state_processes": 0,
                "issues": ["vmstat file not found; fail-open."],
            },
            "metrics": {},
            "d_state_procs": [],
        }

    try:
        with open(vmstat_path, "r") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 2:
                    k, v = parts[0], parts[1]
                    if k == "nr_dirty":
                        nr_dirty = int(v)
                    elif k == "nr_writeback":
                        nr_writeback = int(v)
                    elif k == "nr_dirty_threshold":
                        nr_dirty_threshold = int(v)
                    elif k == "nr_dirty_background_threshold":
                        nr_dirty_bg_threshold = int(v)
    except Exception as e:
        issues.append(f"Failed to parse vmstat: {str(e)}")

    dirty_mb = round((nr_dirty * PAGE_SIZE_KB) / 1024.0, 2)
    writeback_mb = round((nr_writeback * PAGE_SIZE_KB) / 1024.0, 2)

    # Compute saturation against dirty threshold (synchronous throttle limit)
    saturation_pct = 0.0
    if nr_dirty_threshold > 0:
        saturation_pct = round((nr_dirty / nr_dirty_threshold) * 100.0, 2)

    bg_saturation_pct = 0.0
    if nr_dirty_bg_threshold > 0:
        bg_saturation_pct = round((nr_dirty / nr_dirty_bg_threshold) * 100.0, 2)

    # Check for processes currently stalled in D (uninterruptible disk sleep) state
    d_state_procs = []
    try:
        for p in glob.glob(os.path.join(proc_dir, "[0-9]*")):
            stat_file = os.path.join(p, "stat")
            if os.path.exists(stat_file):
                try:
                    with open(stat_file, "r") as f:
                        content = f.read()
                        # Extract state which is the char right after the last closing paren
                        rparen = content.rfind(")")
                        if rparen != -1 and len(content) > rparen + 2:
                            state = content[rparen + 2]
                            if state == "D":
                                pid_str = os.path.basename(p)
                                comm = content[content.find("(") + 1 : rparen]
                                d_state_procs.append({"pid": int(pid_str), "comm": comm})
                except Exception:
                    continue
    except Exception:
        pass

    if saturation_pct >= crit_sat_pct:
        issues.append(
            f"Severe dirty page saturation: {saturation_pct}% ({dirty_mb} MB / {nr_dirty} pages). Kernel writeback throttling imminent or active."
        )
    elif saturation_pct >= warn_sat_pct:
        issues.append(
            f"Elevated dirty page saturation: {saturation_pct}% ({dirty_mb} MB / {nr_dirty} pages) approaching synchronous throttle threshold."
        )

    if d_state_procs:
        issues.append(
            f"{len(d_state_procs)} process(es) currently stalled in uninterruptible disk sleep (D state): {', '.join([p['comm'] for p in d_state_procs[:5]])}"
        )

    status = "HEALTHY"
    if any("Severe" in iss for iss in issues):
        status = "CRITICAL"
    elif issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "nr_dirty_pages": nr_dirty,
            "nr_writeback_pages": nr_writeback,
            "dirty_mb": dirty_mb,
            "writeback_mb": writeback_mb,
            "saturation_pct": saturation_pct,
            "bg_saturation_pct": bg_saturation_pct,
            "dirty_threshold_pages": nr_dirty_threshold,
            "dirty_bg_threshold_pages": nr_dirty_bg_threshold,
            "d_state_processes": len(d_state_procs),
            "issues": issues,
        },
        "metrics": {
            "nr_dirty": nr_dirty,
            "nr_writeback": nr_writeback,
            "nr_dirty_threshold": nr_dirty_threshold,
            "nr_dirty_background_threshold": nr_dirty_bg_threshold,
            "dirty_mb": dirty_mb,
            "writeback_mb": writeback_mb,
        },
        "d_state_procs": d_state_procs[:20],
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Kernel Dirty Memory Page Writeback & Throttling Stall Guard (Pattern 88)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument(
        "--warn-saturation-pct",
        type=float,
        default=DEFAULT_WARN_SATURATION_PCT,
        help=f"Warning dirty saturation percentage (default {DEFAULT_WARN_SATURATION_PCT}%%)",
    )
    parser.add_argument(
        "--crit-saturation-pct",
        type=float,
        default=DEFAULT_CRIT_SATURATION_PCT,
        help=f"Critical dirty saturation percentage (default {DEFAULT_CRIT_SATURATION_PCT}%%)",
    )
    parser.add_argument(
        "--vmstat-path",
        type=str,
        default=DEFAULT_VMSTAT_PATH,
        help="Path to /proc/vmstat",
    )
    parser.add_argument(
        "--proc-dir",
        type=str,
        default=DEFAULT_PROC_DIR,
        help="Path to /proc",
    )

    args = parser.parse_args()

    result = audit_dirty_writeback(
        vmstat_path=args.vmstat_path,
        proc_dir=args.proc_dir,
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
    print(" Jev Multi-Agent Kernel Dirty Memory Page Writeback Guard (Pattern 88)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    print(f" Dirty Cache Footprint:  {summary['dirty_mb']} MB ({summary['nr_dirty_pages']:,} pages)")
    print(f" In-Flight Writebacks:   {summary['writeback_mb']} MB ({summary['nr_writeback_pages']:,} pages)")
    print(f" Throttle Saturation:    {summary['saturation_pct']}% of sync throttle limit ({summary['dirty_threshold_pages']:,} pages)")
    print(f" Flusher Saturation:     {summary['bg_saturation_pct']}% of background threshold ({summary['dirty_bg_threshold_pages']:,} pages)")
    print(f" D-State Stalled Procs:  {summary['d_state_processes']} process(es)")

    if result["d_state_procs"]:
        print("\nProcesses in Uninterruptible Disk Sleep (D state):")
        for proc in result["d_state_procs"]:
            print(f"  - PID {proc['pid']:<7} {proc['comm']}")

    if summary["issues"]:
        print("\nActive Writeback Pressure Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nKernel memory writeback subsystem nominal. Zero dirty page stalls or D-state I/O hangs.")
    print("================================================================================")


if __name__ == "__main__":
    main()
