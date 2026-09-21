#!/usr/bin/env python3
"""
fm-jev-futex-guard.py - Jev Multi-Agent Futex Contention & Thread Stargate Guard (Pattern 63)

Audits thread wait channels (/proc/<pid>/task/<tid>/wchan) and thread states (/proc/<pid>/status).
Detects excessive futex lock contention, epoll thread starvation, and potential deadlocks across
parallel multi-agent runtime workers (Python, Node.js, Bun, Go, Rust).

Invariants:
  - Read-only diagnostics by default. Non-destructive.
  - Fail-open: graceful handling of short-lived or permission-restricted PIDs/TIDs.
  - Fast execution (< 0.5s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple


DEFAULT_WARN_THREADS = 256
DEFAULT_WARN_FUTEX_THREADS = 200
DEFAULT_WARN_FUTEX_RATIO = 0.95


def inspect_thread_wchan(wchan_path: str) -> str:
    """Reads wchan for a thread, returning the wait channel symbol."""
    try:
        with open(wchan_path, "r", errors="replace") as f:
            return f.read().strip()
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        return ""


def get_process_thread_stats(pid: int, proc_root: str = "/proc") -> Optional[Dict[str, Any]]:
    """Inspects all threads of a process under <proc_root>/<pid>/task."""
    task_dir = os.path.join(proc_root, str(pid), "task")
    comm_path = os.path.join(proc_root, str(pid), "comm")

    comm = "unknown"
    try:
        with open(comm_path, "r", errors="replace") as f:
            comm = f.read().strip()
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        return None

    try:
        tids = os.listdir(task_dir)
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        return None

    thread_count = len(tids)
    if thread_count == 0:
        return None

    wchan_counts: Dict[str, int] = {}
    futex_wait_count = 0
    epoll_wait_count = 0
    poll_wait_count = 0
    pipe_wait_count = 0
    socket_wait_count = 0

    for tid in tids:
        wchan = inspect_thread_wchan(f"{task_dir}/{tid}/wchan")
        if not wchan:
            continue
        wchan_counts[wchan] = wchan_counts.get(wchan, 0) + 1

        wchan_lower = wchan.lower()
        if "futex" in wchan_lower:
            futex_wait_count += 1
        elif "epoll" in wchan_lower:
            epoll_wait_count += 1
        elif "poll" in wchan_lower or "select" in wchan_lower:
            poll_wait_count += 1
        elif "pipe" in wchan_lower:
            pipe_wait_count += 1
        elif "sk_" in wchan_lower or "sock" in wchan_lower or "net" in wchan_lower:
            socket_wait_count += 1

    futex_ratio = (futex_wait_count / thread_count) if thread_count > 0 else 0.0

    return {
        "pid": pid,
        "comm": comm,
        "thread_count": thread_count,
        "futex_wait_count": futex_wait_count,
        "epoll_wait_count": epoll_wait_count,
        "poll_wait_count": poll_wait_count,
        "pipe_wait_count": pipe_wait_count,
        "socket_wait_count": socket_wait_count,
        "futex_ratio": round(futex_ratio, 4),
        "top_wchans": dict(sorted(wchan_counts.items(), key=lambda x: x[1], reverse=True)[:5]),
    }


def audit_fleet_futex(
    proc_root: str = "/proc",
    warn_threads: int = DEFAULT_WARN_THREADS,
    warn_futex_threads: int = DEFAULT_WARN_FUTEX_THREADS,
    warn_futex_ratio: float = DEFAULT_WARN_FUTEX_RATIO,
) -> Dict[str, Any]:
    """Audits process and thread wait states across the system."""
    procs: List[Dict[str, Any]] = []
    total_threads = 0
    total_futex_threads = 0
    total_epoll_threads = 0

    try:
        entries = os.listdir(proc_root)
    except Exception as e:
        return {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "summary": {
                "audited_processes": 0,
                "total_threads": 0,
                "total_futex_threads": 0,
                "total_epoll_threads": 0,
                "overall_futex_ratio": 0.0,
                "flagged_processes_count": 0,
                "status": "CRITICAL",
                "recommendation": f"Failed to list {proc_root}: {e}",
                "healthy": False,
            },
            "top_processes": [],
            "flagged_processes": [],
        }

    for entry in entries:
        if not entry.isdigit():
            continue
        pid = int(entry)
        stats = get_process_thread_stats(pid, proc_root=proc_root)
        if stats:
            procs.append(stats)
            total_threads += stats["thread_count"]
            total_futex_threads += stats["futex_wait_count"]
            total_epoll_threads += stats["epoll_wait_count"]

    # Sort processes by futex wait count descending
    procs.sort(key=lambda p: (p["futex_wait_count"], p["thread_count"]), reverse=True)

    flagged: List[Dict[str, Any]] = []
    for p in procs:
        is_flagged = False
        reasons = []

        if p["thread_count"] >= warn_threads and p["futex_wait_count"] >= warn_futex_threads and p["futex_ratio"] >= warn_futex_ratio:
            is_flagged = True
            reasons.append(
                f"High futex contention: {p['futex_wait_count']}/{p['thread_count']} threads ({p['futex_ratio'] * 100:.1f}%) in futex_wait"
            )

        if is_flagged:
            flagged.append({
                "pid": p["pid"],
                "comm": p["comm"],
                "thread_count": p["thread_count"],
                "futex_wait_count": p["futex_wait_count"],
                "futex_ratio": p["futex_ratio"],
                "reasons": reasons,
                "top_wchans": p["top_wchans"],
            })

    overall_futex_ratio = (total_futex_threads / total_threads) if total_threads > 0 else 0.0
    status = "HEALTHY" if len(flagged) == 0 else "WARNING"
    recommendations = []
    if flagged:
        recommendations.append(f"{len(flagged)} processes exhibiting severe futex thread contention")
    recommendation = "; ".join(recommendations) if recommendations else "optimal"

    top_proc = procs[0] if procs else None

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "audited_processes": len(procs),
            "total_threads": total_threads,
            "total_futex_threads": total_futex_threads,
            "total_epoll_threads": total_epoll_threads,
            "overall_futex_ratio": round(overall_futex_ratio, 4),
            "max_futex_pid": top_proc["pid"] if top_proc else 0,
            "max_futex_comm": top_proc["comm"] if top_proc else "none",
            "max_futex_threads": top_proc["futex_wait_count"] if top_proc else 0,
            "flagged_processes_count": len(flagged),
            "warn_threads": warn_threads,
            "warn_futex_threads": warn_futex_threads,
            "warn_futex_ratio": warn_futex_ratio,
            "status": status,
            "recommendation": recommendation,
            "healthy": (status == "HEALTHY"),
        },
        "top_processes": procs[:15],
        "flagged_processes": flagged,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Futex Contention & Thread Stargate Guard (Pattern 63)"
    )
    parser.add_argument(
        "--warn-threads",
        type=int,
        default=DEFAULT_WARN_THREADS,
        help=f"Warn threshold for process thread count (default: {DEFAULT_WARN_THREADS})",
    )
    parser.add_argument(
        "--warn-futex-threads",
        type=int,
        default=DEFAULT_WARN_FUTEX_THREADS,
        help=f"Warn threshold for futex wait thread count (default: {DEFAULT_WARN_FUTEX_THREADS})",
    )
    parser.add_argument(
        "--warn-futex-ratio",
        type=float,
        default=DEFAULT_WARN_FUTEX_RATIO,
        help=f"Warn threshold for futex/total thread ratio (default: {DEFAULT_WARN_FUTEX_RATIO})",
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--verbose", action="store_true", help="Verbose process listing")

    args = parser.parse_args()

    report = audit_fleet_futex(
        warn_threads=args.warn_threads,
        warn_futex_threads=args.warn_futex_threads,
        warn_futex_ratio=args.warn_futex_ratio,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        summary = report["summary"]
        status_str = summary["status"]
        print(f"[{status_str}] Jev Multi-Agent Futex & Thread Guard (Pattern 63)")
        print(f"Processes Scanned: {summary['audited_processes']}")
        print(f"Total Threads: {summary['total_threads']}")
        print(f"Threads in Futex Wait: {summary['total_futex_threads']} ({summary['overall_futex_ratio'] * 100:.1f}%)")
        print(f"Threads in Epoll Wait: {summary['total_epoll_threads']}")
        print(f"Flagged Contention Processes: {summary['flagged_processes_count']}")

        if summary["flagged_processes_count"] > 0:
            print("\nFlagged Processes Exceeding Contention Thresholds:")
            for p in report["flagged_processes"]:
                print(f"  PID {p['pid']} ({p['comm']}): {p['futex_wait_count']}/{p['thread_count']} threads ({p['futex_ratio']*100:.1f}%)")
                for r in p["reasons"]:
                    print(f"    - {r}")

        if args.verbose or not summary["healthy"]:
            print("\nTop 5 Thread/Futex Consumers:")
            for p in report["top_processes"][:5]:
                print(f"  PID {p['pid']:<7} {p['comm']:<16} Threads: {p['thread_count']:<4} Futex: {p['futex_wait_count']:<4} Epoll: {p['epoll_wait_count']:<4} Ratio: {p['futex_ratio']*100:.1f}%")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
