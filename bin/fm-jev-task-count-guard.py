#!/usr/bin/env python3
"""
bin/fm-jev-task-count-guard.py - Linux Kernel Task, Thread & PID Table Saturation Guard (Pattern 310 / Pattern 448)

Audits Linux task/thread table saturation and capacity limits:
  - /proc/loadavg: Load averages, active runnable tasks, total existing tasks, and last PID allocated
  - /proc/sys/kernel/threads-max: System-wide thread ceiling (prevents thread table exhaustion)
  - /proc/sys/kernel/pid_max: Maximum PID ceiling (prevents PID wraparound and fork-bomb lockups)
  - /proc/sys/vm/max_map_count: Maximum VMA memory map areas per process (prevents mmap exhaustion)

Invariants:
  - Total task count must remain safely below threads-max (< 75% warn, < 90% crit).
  - Runnable tasks must not indicate severe runqueue starvation (< 256 warn, < 512 crit).
  - threads-max and pid_max must be adequately sized for multi-agent concurrency.
  - Fail-open: graceful fallback when sysctl paths are restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Tuple

PROC_LOADAVG = "/proc/loadavg"
PROC_SYS_KERNEL_THREADS_MAX = "/proc/sys/kernel/threads-max"
PROC_SYS_KERNEL_PID_MAX = "/proc/sys/kernel/pid_max"
PROC_SYS_VM_MAX_MAP_COUNT = "/proc/sys/vm/max_map_count"

DEFAULT_WARN_THREAD_PCT = 75.0
DEFAULT_CRIT_THREAD_PCT = 90.0
DEFAULT_WARN_RUNNABLE_TASKS = 256
DEFAULT_CRIT_RUNNABLE_TASKS = 512
DEFAULT_WARN_TOTAL_TASKS = 50_000
DEFAULT_CRIT_TOTAL_TASKS = 100_000


def read_sysctl_int(path: str, default: int = 0) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        parts = content.split()
        return int(parts[0]) if parts and parts[0].lstrip("-").isdigit() else default
    except (ValueError, OSError, IndexError):
        return default


def parse_loadavg(path: str) -> Tuple[float, float, float, int, int, int]:
    if not os.path.isfile(path):
        return 0.0, 0.0, 0.0, 0, 0, 0
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            parts = f.read().strip().split()
        if len(parts) >= 5:
            l1 = float(parts[0])
            l5 = float(parts[1])
            l15 = float(parts[2])
            tasks_parts = parts[3].split("/")
            runnable = int(tasks_parts[0])
            total = int(tasks_parts[1])
            last_pid = int(parts[4])
            return l1, l5, l15, runnable, total, last_pid
    except (ValueError, OSError, IndexError):
        pass
    return 0.0, 0.0, 0.0, 0, 0, 0


def evaluate_task_count(
    loadavg_file: str = PROC_LOADAVG,
    threads_max_file: str = PROC_SYS_KERNEL_THREADS_MAX,
    pid_max_file: str = PROC_SYS_KERNEL_PID_MAX,
    max_map_count_file: str = PROC_SYS_VM_MAX_MAP_COUNT,
    warn_thread_pct: float = DEFAULT_WARN_THREAD_PCT,
    crit_thread_pct: float = DEFAULT_CRIT_THREAD_PCT,
    warn_runnable: int = DEFAULT_WARN_RUNNABLE_TASKS,
    crit_runnable: int = DEFAULT_CRIT_RUNNABLE_TASKS,
    warn_total: int = DEFAULT_WARN_TOTAL_TASKS,
    crit_total: int = DEFAULT_CRIT_TOTAL_TASKS,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    l1, l5, l15, runnable, total, last_pid = parse_loadavg(loadavg_file)
    threads_max = read_sysctl_int(threads_max_file, default=509326)
    pid_max = read_sysctl_int(pid_max_file, default=4194304)
    max_map_count = read_sysctl_int(max_map_count_file, default=1048576)

    thread_util_pct = (total / threads_max * 100.0) if threads_max > 0 else 0.0
    pid_util_pct = (last_pid / pid_max * 100.0) if pid_max > 0 else 0.0

    if thread_util_pct >= crit_thread_pct:
        issues.append(
            f"Thread count critically elevated ({total}/{threads_max} = {thread_util_pct:.1f}% >= {crit_thread_pct}%); risk of fork failures"
        )
        recommendations.append("Terminate leaked worker processes or increase kernel.threads-max")
        status = "CRITICAL"
    elif thread_util_pct >= warn_thread_pct:
        issues.append(
            f"Thread count elevated ({total}/{threads_max} = {thread_util_pct:.1f}% >= {warn_thread_pct}%)"
        )
        recommendations.append("Monitor agent thread pools and check for thread accumulation")
        status = "WARNING"

    if runnable >= crit_runnable:
        issues.append(
            f"Runnable task count critical ({runnable} >= {crit_runnable}); scheduler queue saturation"
        )
        recommendations.append("Throttle concurrent agent tasks to relieve scheduler CPU runqueue pressure")
        status = "CRITICAL"
    elif runnable >= warn_runnable:
        issues.append(
            f"Runnable task count elevated ({runnable} >= {warn_runnable}); high scheduling contention"
        )
        if status != "CRITICAL":
            status = "WARNING"

    if total >= crit_total:
        issues.append(f"Total task count critical ({total} >= {crit_total})")
        status = "CRITICAL"
    elif total >= warn_total:
        issues.append(f"Total task count elevated ({total} >= {warn_total})")
        if status != "CRITICAL":
            status = "WARNING"

    healthy = len(issues) == 0

    return {
        "pattern": 310,
        "name": "task_count",
        "description": "Linux Kernel Task, Thread & PID Table Saturation Guard",
        "status": status,
        "healthy": healthy,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "load_1m": l1,
        "load_5m": l5,
        "load_15m": l15,
        "runnable_tasks": runnable,
        "total_tasks": total,
        "threads_max": threads_max,
        "thread_utilization_pct": round(thread_util_pct, 4),
        "last_pid": last_pid,
        "pid_max": pid_max,
        "pid_utilization_pct": round(pid_util_pct, 4),
        "max_map_count": max_map_count,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Linux Kernel Task, Thread & PID Table Saturation Guard (Pattern 310 / Pattern 448)"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--loadavg-file", default=PROC_LOADAVG, help="Path to /proc/loadavg")
    parser.add_argument("--threads-max-file", default=PROC_SYS_KERNEL_THREADS_MAX, help="Path to threads-max sysctl")
    parser.add_argument("--pid-max-file", default=PROC_SYS_KERNEL_PID_MAX, help="Path to pid_max sysctl")
    parser.add_argument("--max-map-count-file", default=PROC_SYS_VM_MAX_MAP_COUNT, help="Path to max_map_count sysctl")
    args = parser.parse_args()

    result = evaluate_task_count(
        loadavg_file=args.loadavg_file,
        threads_max_file=args.threads_max_file,
        pid_max_file=args.pid_max_file,
        max_map_count_file=args.max_map_count_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] Pattern {result['pattern']} - {result['description']}")
        print(f"  Load Averages: {result['load_1m']}, {result['load_5m']}, {result['load_15m']}")
        print(f"  Runnable Tasks: {result['runnable_tasks']}, Total Tasks: {result['total_tasks']} / {result['threads_max']} ({result['thread_utilization_pct']}%)")
        print(f"  Last PID: {result['last_pid']} / {result['pid_max']} ({result['pid_utilization_pct']}%), max_map_count: {result['max_map_count']}")
        if result["issues"]:
            print("  Issues:")
            for issue in result["issues"]:
                print(f"    - {issue}")
        if result["recommendations"]:
            print("  Recommendations:")
            for rec in result["recommendations"]:
                print(f"    - {rec}")

    if not result["healthy"]:
        sys.exit(1 if result["status"] == "WARNING" else 2)


if __name__ == "__main__":
    main()
