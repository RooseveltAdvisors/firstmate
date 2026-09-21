#!/usr/bin/env python3
"""
fm-jev-mem-guard.py - Jev Multi-Agent Memory RSS & Swap Thrashing Guard (Pattern 46)

Audits host memory availability (/proc/meminfo) and swap utilization to detect memory
starvation, swap thrashing, and out-of-control worker RSS expansion across multi-agent seats.
Prevents catastrophic OOM killer invocations against persistent agent supervisors and tmux sessions.

Invariants:
  - Read-only diagnostics.
  - Fail-open: graceful fallback on permission issues or virtualized environments.
  - Bounded sub-second execution (< 500ms).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Tuple


def read_meminfo() -> Dict[str, int]:
    """Reads and parses /proc/meminfo in kB."""
    info: Dict[str, int] = {}
    try:
        with open("/proc/meminfo", "r") as f:
            for line in f:
                parts = line.split(":")
                if len(parts) == 2:
                    key = parts[0].strip()
                    val_parts = parts[1].strip().split()
                    if val_parts and val_parts[0].isdigit():
                        info[key] = int(val_parts[0])
    except Exception:
        pass
    return info


def get_top_rss_processes(top_n: int = 10) -> List[Dict[str, Any]]:
    """Inspects /proc to find top memory-consuming processes by RSS."""
    procs: List[Dict[str, Any]] = []
    page_size_kb = os.sysconf("SC_PAGE_SIZE") // 1024 if hasattr(os, "sysconf") else 4

    try:
        entries = os.listdir("/proc")
    except Exception:
        return []

    for entry in entries:
        if not entry.isdigit():
            continue
        pid = int(entry)
        try:
            with open(f"/proc/{pid}/statm", "r") as f:
                parts = f.read().strip().split()
                if len(parts) >= 2 and parts[1].isdigit():
                    rss_pages = int(parts[1])
                    rss_kb = rss_pages * page_size_kb
                    if rss_kb < 10240:  # Skip procs using < 10MB
                        continue

            comm = f"pid_{pid}"
            try:
                with open(f"/proc/{pid}/comm", "r", errors="replace") as f:
                    comm = f.read().strip()
            except Exception:
                pass

            procs.append({
                "pid": pid,
                "comm": comm,
                "rss_mb": round(rss_kb / 1024.0, 1),
            })
        except Exception:
            continue

    procs.sort(key=lambda p: p["rss_mb"], reverse=True)
    return procs[:top_n]


def audit_memory(
    warn_mem_pct: float = 90.0,
    crit_mem_pct: float = 95.0,
    warn_swap_pct: float = 85.0,
    crit_swap_pct: float = 95.0,
    top_n: int = 10,
) -> Dict[str, Any]:
    """Audits system memory and swap usage."""
    mem = read_meminfo()
    mem_total_kb = mem.get("MemTotal", 1)
    mem_avail_kb = mem.get("MemAvailable", mem.get("MemFree", 0))
    swap_total_kb = mem.get("SwapTotal", 0)
    swap_free_kb = mem.get("SwapFree", 0)

    mem_used_kb = max(0, mem_total_kb - mem_avail_kb)
    mem_used_pct = round((mem_used_kb / mem_total_kb) * 100.0, 1)

    swap_used_kb = max(0, swap_total_kb - swap_free_kb)
    swap_used_pct = (
        round((swap_used_kb / swap_total_kb) * 100.0, 1) if swap_total_kb > 0 else 0.0
    )

    top_procs = get_top_rss_processes(top_n=top_n)

    # Determine status
    if mem_used_pct >= crit_mem_pct or swap_used_pct >= crit_swap_pct:
        status = "CRITICAL"
        healthy = False
    elif mem_used_pct >= warn_mem_pct or swap_used_pct >= warn_swap_pct:
        status = "WARNING"
        healthy = False
    else:
        status = "HEALTHY"
        healthy = True

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "mem_total_gb": round(mem_total_kb / (1024.0 * 1024.0), 2),
            "mem_available_gb": round(mem_avail_kb / (1024.0 * 1024.0), 2),
            "mem_used_pct": mem_used_pct,
            "swap_total_gb": round(swap_total_kb / (1024.0 * 1024.0), 2),
            "swap_used_gb": round(swap_used_kb / (1024.0 * 1024.0), 2),
            "swap_used_pct": swap_used_pct,
            "status": status,
            "healthy": healthy,
        },
        "top_processes": top_procs,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Memory RSS & Swap Thrashing Guard (Pattern 46)"
    )
    parser.add_argument(
        "--warn-mem-pct",
        type=float,
        default=90.0,
        help="Warning threshold for memory utilization %% (default: 90.0)",
    )
    parser.add_argument(
        "--crit-mem-pct",
        type=float,
        default=95.0,
        help="Critical threshold for memory utilization %% (default: 95.0)",
    )
    parser.add_argument(
        "--warn-swap-pct",
        type=float,
        default=85.0,
        help="Warning threshold for swap utilization %% (default: 85.0)",
    )
    parser.add_argument(
        "--crit-swap-pct",
        type=float,
        default=95.0,
        help="Critical threshold for swap utilization %% (default: 95.0)",
    )
    parser.add_argument(
        "--top",
        type=int,
        default=10,
        help="Number of top RSS processes to list (default: 10)",
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
    report = audit_memory(
        warn_mem_pct=args.warn_mem_pct,
        crit_mem_pct=args.crit_mem_pct,
        warn_swap_pct=args.warn_swap_pct,
        crit_swap_pct=args.crit_swap_pct,
        top_n=args.top,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"Jev Memory RSS & Swap Thrashing Guard (Pattern 46) — {report['timestamp']}")
        print(f"  • RAM: {s['mem_used_pct']}% used ({s['mem_available_gb']} GB available / {s['mem_total_gb']} GB total)")
        print(f"  • Swap: {s['swap_used_pct']}% used ({s['swap_used_gb']} GB used / {s['swap_total_gb']} GB total)")
        print(f"  • Status: {s['status']}")
        if report["top_processes"]:
            print(f"\n  Top {len(report['top_processes'])} RSS Processes:")
            for p in report["top_processes"]:
                print(f"    - PID {p['pid']} ({p['comm']}): {p['rss_mb']} MB")

    if args.check and not report["summary"]["healthy"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
