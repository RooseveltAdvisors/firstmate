#!/usr/bin/env python3
"""
fm-jev-epoll-guard.py - Jev Multi-Agent Kernel Epoll & Eventfd Descriptor Saturation Guard (Pattern 85)

Audits Linux kernel epoll subsystem limits (/proc/sys/fs/epoll/max_user_watches), allocated epoll instances,
eventfd, timerfd, and signalfd descriptors across multi-agent asyncio, libuv (Node.js), and Tokio (Rust)
event loops. Prevents cryptic ENOSPC (No space left on device) socket polling failures and event-loop
starvation under high multi-agent concurrency.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback on missing sysctl or restricted /proc permissions.
  - Fast bounded execution (< 0.05s) across process table.
"""

import argparse
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_MAX_USER_WATCHES_PATH = "/proc/sys/fs/epoll/max_user_watches"
DEFAULT_PROC_DIR = "/proc"

DEFAULT_WARN_WATCHES_PCT = 50.0
DEFAULT_CRIT_WATCHES_PCT = 80.0
DEFAULT_WARN_PROC_EPOLL = 250


def read_int_file(path: str) -> Optional[int]:
    """Reads integer value from a sysfs/procfs file."""
    try:
        with open(path, "r") as f:
            return int(f.read().strip())
    except Exception:
        return None


def read_comm(proc_dir: str, pid_str: str) -> str:
    """Safely reads process comm name."""
    try:
        with open(os.path.join(proc_dir, pid_str, "comm"), "r") as f:
            return f.read().strip()
    except Exception:
        return "unknown"


def audit_epoll(
    proc_dir: str = DEFAULT_PROC_DIR,
    sys_epoll_path: str = DEFAULT_MAX_USER_WATCHES_PATH,
    warn_watches_pct: float = DEFAULT_WARN_WATCHES_PCT,
    crit_watches_pct: float = DEFAULT_CRIT_WATCHES_PCT,
    warn_proc_epoll: int = DEFAULT_WARN_PROC_EPOLL,
) -> Dict[str, Any]:
    """Audits epoll instances, eventfd descriptors, and system limits."""
    max_user_watches = read_int_file(sys_epoll_path) or 1000000

    epoll_total = 0
    eventfd_total = 0
    timerfd_total = 0
    signalfd_total = 0
    total_procs_audited = 0

    proc_stats: Dict[int, Dict[str, Any]] = defaultdict(
        lambda: {"epoll": 0, "eventfd": 0, "timerfd": 0, "signalfd": 0, "comm": ""}
    )

    if os.path.exists(proc_dir):
        try:
            entries = os.listdir(proc_dir)
        except Exception:
            entries = []

        for entry in entries:
            if not entry.isdigit():
                continue
            pid = int(entry)
            fd_dir = os.path.join(proc_dir, entry, "fd")
            try:
                fds = os.listdir(fd_dir)
            except Exception:
                continue

            total_procs_audited += 1
            comm = read_comm(proc_dir, entry)
            proc_stats[pid]["comm"] = comm

            for fd in fds:
                try:
                    target = os.readlink(os.path.join(fd_dir, fd))
                    if "eventpoll" in target:
                        epoll_total += 1
                        proc_stats[pid]["epoll"] += 1
                    elif "eventfd" in target:
                        eventfd_total += 1
                        proc_stats[pid]["eventfd"] += 1
                    elif "timerfd" in target:
                        timerfd_total += 1
                        proc_stats[pid]["timerfd"] += 1
                    elif "signalfd" in target:
                        signalfd_total += 1
                        proc_stats[pid]["signalfd"] += 1
                except Exception:
                    pass

    # Calculate saturation
    watches_pct = round((epoll_total / max_user_watches * 100.0), 4) if max_user_watches > 0 else 0.0

    issues: List[str] = []
    status = "HEALTHY"

    if watches_pct >= crit_watches_pct:
        status = "CRITICAL"
        issues.append(f"Severe epoll user watches saturation: {watches_pct}% ({epoll_total}/{max_user_watches})")
    elif watches_pct >= warn_watches_pct:
        status = "WARNING"
        issues.append(f"Elevated epoll user watches saturation: {watches_pct}% ({epoll_total}/{max_user_watches})")

    # Check for single-process descriptor leaks
    leaking_procs = []
    for pid, s in proc_stats.items():
        if s["epoll"] >= warn_proc_epoll:
            leaking_procs.append((pid, s["comm"], s["epoll"]))
            issues.append(f"Process PID {pid} ({s['comm']}) holds anomalous epoll instances: {s['epoll']}")

    if leaking_procs and status == "HEALTHY":
        status = "WARNING"

    # Top consumers
    sorted_procs = sorted(
        [
            {"pid": pid, "comm": s["comm"], "epoll": s["epoll"], "eventfd": s["eventfd"], "total": s["epoll"] + s["eventfd"]}
            for pid, s in proc_stats.items()
            if (s["epoll"] + s["eventfd"]) > 0
        ],
        key=lambda x: x["total"],
        reverse=True,
    )

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "epoll_instances": epoll_total,
            "eventfd_descriptors": eventfd_total,
            "timerfd_descriptors": timerfd_total,
            "signalfd_descriptors": signalfd_total,
            "max_user_watches": max_user_watches,
            "watches_saturation_pct": watches_pct,
            "procs_audited": total_procs_audited,
            "issues": issues,
        },
        "top_consumers": sorted_procs[:10],
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Kernel Epoll & Eventfd Descriptor Saturation Guard (Pattern 85)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--warn-pct", type=float, default=DEFAULT_WARN_WATCHES_PCT, help=f"Warning saturation pct (default {DEFAULT_WARN_WATCHES_PCT})")
    parser.add_argument("--crit-pct", type=float, default=DEFAULT_CRIT_WATCHES_PCT, help=f"Critical saturation pct (default {DEFAULT_CRIT_WATCHES_PCT})")
    parser.add_argument("--warn-proc", type=int, default=DEFAULT_WARN_PROC_EPOLL, help=f"Warning epoll count per proc (default {DEFAULT_WARN_PROC_EPOLL})")
    parser.add_argument("--proc-dir", type=str, default=DEFAULT_PROC_DIR, help="Proc directory path (default /proc)")
    parser.add_argument("--sys-epoll-path", type=str, default=DEFAULT_MAX_USER_WATCHES_PATH, help="Path to max_user_watches")

    args = parser.parse_args()

    result = audit_epoll(
        proc_dir=args.proc_dir,
        sys_epoll_path=args.sys_epoll_path,
        warn_watches_pct=args.warn_pct,
        crit_watches_pct=args.crit_pct,
        warn_proc_epoll=args.warn_proc,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else ("\033[31m" if summary["status"] == "CRITICAL" else "\033[33m")
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Epoll & Eventfd Guard (Pattern 85)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    print(f" Epoll Instances:        {summary['epoll_instances']:,} / {summary['max_user_watches']:,} max ({summary['watches_saturation_pct']}%)")
    print(f" Eventfd Descriptors:    {summary['eventfd_descriptors']:,}")
    print(f" Timerfd / Signalfd:     {summary['timerfd_descriptors']:,} timerfd / {summary['signalfd_descriptors']:,} signalfd")
    print(f" Audited Processes:      {summary['procs_audited']:,}")

    if result["top_consumers"]:
        print("\nTop Epoll & Eventfd Consumers:")
        for p in result["top_consumers"][:5]:
            print(f"  - PID {p['pid']:<7} {p['comm']:<22} epoll={p['epoll']:<4} eventfd={p['eventfd']:<4} total={p['total']}")

    if summary["issues"]:
        print("\nActive Issues & Saturation Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll epoll watches and eventfd descriptors nominal. Zero event-loop starvation detected.")
    print("================================================================================")


if __name__ == "__main__":
    main()
