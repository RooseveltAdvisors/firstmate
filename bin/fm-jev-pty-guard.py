#!/usr/bin/env python3
"""
fm-jev-pty-guard.py - Jev Multi-Agent PTY/TTY Allocation & Pseudoterminal Exhaustion Guard (Pattern 47)

Audits host pseudo-terminal allocation (/proc/sys/kernel/pty/nr vs /proc/sys/kernel/pty/max)
and active /dev/pts instances across multi-agent processes (tmux, pi, claude, agy, bash).
Prevents catastrophic "openpty failed: Device or resource busy" and "forkpty failed" errors
caused by leaked agent terminal wrappers or hanging subshells.

Invariants:
  - Read-only diagnostics.
  - Fail-open: graceful fallback if /proc/sys/kernel/pty is inaccessible.
  - Bounded sub-second execution (< 500ms).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List


def get_pty_limits() -> Dict[str, int]:
    """Reads /proc/sys/kernel/pty/nr and /proc/sys/kernel/pty/max."""
    nr = 0
    max_pty = 4096  # Standard Linux fallback
    try:
        with open("/proc/sys/kernel/pty/nr", "r") as f:
            nr = int(f.read().strip())
    except Exception:
        pass

    try:
        with open("/proc/sys/kernel/pty/max", "r") as f:
            max_pty = int(f.read().strip())
    except Exception:
        pass

    return {"nr": nr, "max": max_pty}


def audit_pty_usage(
    warn_pct: float = 75.0,
    crit_pct: float = 90.0,
) -> Dict[str, Any]:
    """Audits system PTY allocation and computes utilization."""
    limits = get_pty_limits()
    nr = limits["nr"]
    max_pty = limits["max"]

    util_pct = round((nr / max_pty) * 100.0, 1) if max_pty > 0 else 0.0

    # Count entries in /dev/pts if accessible
    dev_pts_count = 0
    try:
        pts_entries = os.listdir("/dev/pts")
        dev_pts_count = sum(1 for e in pts_entries if e.isdigit())
    except Exception:
        pass

    if util_pct >= crit_pct:
        status = "CRITICAL"
        healthy = False
    elif util_pct >= warn_pct:
        status = "WARNING"
        healthy = False
    else:
        status = "HEALTHY"
        healthy = True

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "allocated_pty": nr,
            "max_pty": max_pty,
            "dev_pts_nodes": dev_pts_count,
            "utilization_pct": util_pct,
            "warn_pct": warn_pct,
            "crit_pct": crit_pct,
            "status": status,
            "healthy": healthy,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent PTY/TTY Allocation & Pseudoterminal Exhaustion Guard (Pattern 47)"
    )
    parser.add_argument(
        "--warn-pct",
        type=float,
        default=75.0,
        help="Warning threshold for PTY utilization %% (default: 75.0)",
    )
    parser.add_argument(
        "--crit-pct",
        type=float,
        default=90.0,
        help="Critical threshold for PTY utilization %% (default: 90.0)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry to stdout",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit with code 0 if healthy, code 1 if warning or critical",
    )

    args = parser.parse_args()
    report = audit_pty_usage(
        warn_pct=args.warn_pct,
        crit_pct=args.crit_pct,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"Jev PTY/TTY Allocation Guard (Pattern 47) — {report['timestamp']}")
        print(f"  • Allocated PTYs: {s['allocated_pty']} / {s['max_pty']} ({s['utilization_pct']}%)")
        print(f"  • /dev/pts Nodes: {s['dev_pts_nodes']}")
        print(f"  • Status: {s['status']}")

    if args.check and not report["summary"]["healthy"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
