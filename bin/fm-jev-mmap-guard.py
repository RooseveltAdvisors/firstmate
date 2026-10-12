#!/usr/bin/env python3
"""
fm-jev-mmap-guard.py - Jev Multi-Agent Memory-Mapped (mmap) Arena & VMA Guard (Pattern 62)

Audits kernel virtual memory area (VMA) mappings (/proc/<pid>/maps) and /proc/sys/vm/max_map_count.
Prevents "Cannot allocate memory" (ENOMEM) crashes when language runtimes (Node, Python, Go),
database engines (PostgreSQL, SQLite), or VLLM workers exhaust process memory map limits.

Invariants:
  - Read-only diagnostics by default. Non-destructive.
  - Fail-open: graceful fallback on permission-restricted or ephemeral PIDs.
  - Bounded fast execution (< 0.5s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple


DEFAULT_VMA_WARN_RATIO = 0.50  # 50% of max_map_count
DEFAULT_VMA_WARN_COUNT = 65536


def get_max_map_count() -> int:
    """Reads /proc/sys/vm/max_map_count safely."""
    try:
        with open("/proc/sys/vm/max_map_count", "r") as f:
            return int(f.read().strip())
    except Exception:
        return 65530  # Standard Linux default fallback


def get_process_vma_count(pid: int) -> Tuple[int, str]:
    """Counts VMAs in /proc/<pid>/maps and reads process comm."""
    maps_path = f"/proc/{pid}/maps"
    comm_path = f"/proc/{pid}/comm"
    count = 0
    comm = "unknown"

    try:
        with open(maps_path, "r", errors="replace") as f:
            count = sum(1 for _ in f)
        with open(comm_path, "r", errors="replace") as f:
            comm = f.read().strip()
    except (PermissionError, FileNotFoundError, ProcessLookupError):
        pass

    return count, comm


def audit_fleet_mmap(
    warn_ratio: float = DEFAULT_VMA_WARN_RATIO,
    warn_count: int = DEFAULT_VMA_WARN_COUNT,
) -> Dict[str, Any]:
    """Audits process VMA counts against max_map_count."""
    max_map = get_max_map_count()
    proc_reports: List[Dict[str, Any]] = []

    try:
        pids = [int(p) for p in os.listdir("/proc") if p.isdigit()]
    except Exception:
        pids = []

    total_vmas = 0
    flagged_procs: List[Dict[str, Any]] = []

    for pid in pids:
        count, comm = get_process_vma_count(pid)
        if count == 0:
            continue

        total_vmas += count
        ratio = round(count / max(1, max_map), 6)

        is_flagged = (count >= warn_count or ratio >= warn_ratio)
        entry = {
            "pid": pid,
            "comm": comm,
            "vma_count": count,
            "vma_ratio": ratio,
            "flagged": is_flagged,
        }
        proc_reports.append(entry)
        if is_flagged:
            flagged_procs.append(entry)

    proc_reports.sort(key=lambda x: x["vma_count"], reverse=True)
    top_proc = proc_reports[0] if proc_reports else None

    status = "HEALTHY"
    recommendations = []

    if flagged_procs:
        status = "CRITICAL"
        recommendations.append(f"{len(flagged_procs)} processes approaching max_map_count limit ({max_map})")

    recommendation = "; ".join(recommendations) if recommendations else "optimal"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "max_map_count": max_map,
            "audited_processes": len(proc_reports),
            "total_fleet_vmas": total_vmas,
            "max_process_vmas": top_proc["vma_count"] if top_proc else 0,
            "max_process_comm": top_proc["comm"] if top_proc else "none",
            "max_process_pid": top_proc["pid"] if top_proc else 0,
            "max_process_ratio": top_proc["vma_ratio"] if top_proc else 0.0,
            "flagged_processes_count": len(flagged_procs),
            "warn_threshold_count": warn_count,
            "warn_threshold_ratio": warn_ratio,
            "status": status,
            "recommendation": recommendation,
            "healthy": (status == "HEALTHY"),
        },
        "top_processes": proc_reports[:15],
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Memory-Mapped Arena & VMA Guard (Pattern 62)"
    )
    parser.add_argument(
        "--warn-count",
        type=int,
        default=DEFAULT_VMA_WARN_COUNT,
        help=f"VMA count warning threshold per process (default: {DEFAULT_VMA_WARN_COUNT})",
    )
    parser.add_argument(
        "--warn-ratio",
        type=float,
        default=DEFAULT_VMA_WARN_RATIO,
        help=f"VMA ratio warning threshold relative to max_map_count (default: {DEFAULT_VMA_WARN_RATIO})",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output raw JSON results",
    )

    args = parser.parse_args()

    results = audit_fleet_mmap(
        warn_ratio=args.warn_ratio,
        warn_count=args.warn_count,
    )

    if args.json:
        print(json.dumps(results, indent=2))
        return 0 if results["summary"]["healthy"] else 1

    summary = results["summary"]
    print(f"Jev Memory-Mapped VMA Guard (Pattern 62) - {results['timestamp']}")
    print(f"Kernel max_map_count: {summary['max_map_count']}")
    print(f"Audited Processes:   {summary['audited_processes']} (Total VMAs: {summary['total_fleet_vmas']})")
    print(f"Peak VMA Process:    PID {summary['max_process_pid']} ({summary['max_process_comm']}): {summary['max_process_vmas']} VMAs ({summary['max_process_ratio']*100:.2f}%)")
    print(f"Health Status:       {summary['status']}")
    print(f"Recommendation:      {summary['recommendation']}")

    if results["top_processes"]:
        print("\nTop Processes by VMA Mapping Count:")
        for p in results["top_processes"][:10]:
            print(f"  - PID {p['pid']:7d} ({p['comm']:16s}): {p['vma_count']:5d} VMAs ({p['vma_ratio']*100:.3f}%)")

    return 0 if summary["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
