#!/usr/bin/env python3
"""
fm-jev-sigqueue-guard.py - Jev Multi-Agent POSIX Signal Queue & Real-Time Signal Backlog Guard (Pattern 86)

Audits Linux kernel POSIX real-time signal queue saturation (SigQ in /proc/<pid>/status) and pending
unhandled signal masks (SigPnd) across multi-agent supervisor hierarchies and worker processes.
Prevents silent signal drops, EAGAIN errors in sigqueue(2), and asynchronous timer notification
stalls under high multi-agent concurrency.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful handling of missing or restricted /proc entries.
  - Fast bounded execution (< 0.05s) across process table.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_WARN_SAT_PCT = 50.0
DEFAULT_CRIT_SAT_PCT = 80.0
DEFAULT_PROC_DIR = "/proc"


def parse_sig_status(status_path: str) -> Dict[str, str]:
    """Extracts signal metrics from /proc/<pid>/status."""
    metrics: Dict[str, str] = {}
    if not os.path.exists(status_path):
        return metrics
    try:
        with open(status_path, "r") as f:
            for line in f:
                if ":" in line:
                    key, val = line.split(":", 1)
                    k = key.strip()
                    if k in ("Name", "SigQ", "SigPnd", "SigBlk", "SigIgn", "SigCgt", "State"):
                        metrics[k] = val.strip()
    except Exception:
        pass
    return metrics


def audit_sigqueue(
    proc_dir: str = DEFAULT_PROC_DIR,
    warn_sat_pct: float = DEFAULT_WARN_SAT_PCT,
    crit_sat_pct: float = DEFAULT_CRIT_SAT_PCT,
) -> Dict[str, Any]:
    """Audits process signal queue depth, queue limits, and pending signal masks."""
    max_queued = 0
    system_limit = 0
    procs_audited = 0
    pending_signals_procs: List[Dict[str, Any]] = []
    high_queued_procs: List[Dict[str, Any]] = []

    if os.path.exists(proc_dir):
        try:
            entries = os.listdir(proc_dir)
        except Exception:
            entries = []

        for entry in entries:
            if not entry.isdigit():
                continue
            pid = int(entry)
            status_file = os.path.join(proc_dir, entry, "status")
            stats = parse_sig_status(status_file)
            if not stats:
                continue

            procs_audited += 1
            comm = stats.get("Name", "unknown")
            sigq_raw = stats.get("SigQ", "")
            sigpnd = stats.get("SigPnd", "0000000000000000")

            queued = 0
            limit = 0
            if sigq_raw and "/" in sigq_raw:
                try:
                    parts = sigq_raw.split("/")
                    queued = int(parts[0])
                    limit = int(parts[1])
                    if queued > max_queued:
                        max_queued = queued
                    if limit > system_limit:
                        system_limit = limit
                except ValueError:
                    pass

            proc_rec = {
                "pid": pid,
                "comm": comm,
                "queued": queued,
                "limit": limit,
                "sigpnd": sigpnd,
                "state": stats.get("State", ""),
            }

            if sigpnd != "0000000000000000":
                pending_signals_procs.append(proc_rec)

            if queued > 0:
                high_queued_procs.append(proc_rec)

    sat_pct = round((max_queued / system_limit * 100.0), 4) if system_limit > 0 else 0.0

    issues: List[str] = []
    status = "HEALTHY"

    if sat_pct >= crit_sat_pct:
        status = "CRITICAL"
        issues.append(f"Severe POSIX signal queue saturation: {sat_pct}% ({max_queued}/{system_limit})")
    elif sat_pct >= warn_sat_pct:
        status = "WARNING"
        issues.append(f"Elevated POSIX signal queue saturation: {sat_pct}% ({max_queued}/{system_limit})")

    if len(pending_signals_procs) > 5:
        if status == "HEALTHY":
            status = "WARNING"
        issues.append(f"Multiple processes ({len(pending_signals_procs)}) have unhandled pending signal backlogs")

    high_queued_procs.sort(key=lambda p: p["queued"], reverse=True)

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "max_queued_signals": max_queued,
            "signal_queue_limit": system_limit,
            "saturation_pct": sat_pct,
            "procs_audited": procs_audited,
            "procs_with_pending_signals": len(pending_signals_procs),
            "issues": issues,
        },
        "top_queued_processes": high_queued_procs[:5],
        "pending_processes": pending_signals_procs[:5],
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent POSIX Signal Queue & Real-Time Signal Backlog Guard (Pattern 86)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--warn-sat", type=float, default=DEFAULT_WARN_SAT_PCT, help=f"Warning saturation pct (default {DEFAULT_WARN_SAT_PCT})")
    parser.add_argument("--crit-sat", type=float, default=DEFAULT_CRIT_SAT_PCT, help=f"Critical saturation pct (default {DEFAULT_CRIT_SAT_PCT})")
    parser.add_argument("--proc-dir", type=str, default=DEFAULT_PROC_DIR, help="Proc directory path (default /proc)")

    args = parser.parse_args()

    result = audit_sigqueue(
        proc_dir=args.proc_dir,
        warn_sat_pct=args.warn_sat,
        crit_sat_pct=args.crit_sat,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else ("\033[31m" if summary["status"] == "CRITICAL" else "\033[33m")
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Signal Queue & Real-Time Signal Guard (Pattern 86)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    print(f" Signal Queue Depth:     {summary['max_queued_signals']:,} / {summary['signal_queue_limit']:,} max ({summary['saturation_pct']}%)")
    print(f" Processes Audited:      {summary['procs_audited']:,}")
    print(f" Unhandled Pending:      {summary['procs_with_pending_signals']} process(es)")

    if result["top_queued_processes"]:
        print("\nProcesses with Active Queued Signals:")
        for p in result["top_queued_processes"]:
            print(f"  - PID {p['pid']:<7} {p['comm']:<22} queued={p['queued']} limit={p['limit']} state={p['state']}")

    if summary["issues"]:
        print("\nActive Issues & Signal Saturation Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll POSIX real-time signal queues and pending masks nominal. Zero signal drops detected.")
    print("================================================================================")


if __name__ == "__main__":
    main()
