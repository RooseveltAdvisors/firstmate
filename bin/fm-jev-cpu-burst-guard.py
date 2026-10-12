#!/usr/bin/env python3
"""
fm-jev-cpu-burst-guard.py - Jev Multi-Agent Load Derivative & CPU Saturation Burst Dampener (Pattern 51)

Audits short-term CPU load surge dynamics and runnable thread saturation (/proc/loadavg)
against total logical CPU cores to detect rapid concurrency surges and burst worker spawning
before host CPU thrashing and context-switch bottlenecks degrade agent response times.

Invariants:
  - Read-only diagnostics.
  - Fail-open: graceful fallback on missing /proc/loadavg or CPU count detection.
  - Sub-second bounded execution (< 250ms).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, Tuple


def get_cpu_core_count() -> int:
    """Detects available logical CPU count."""
    try:
        count = os.cpu_count()
        return count if count and count > 0 else 1
    except Exception:
        return 1


def parse_loadavg() -> Tuple[float, float, float, int, int]:
    """Parses /proc/loadavg into (load1, load5, load15, runnable, total_procs)."""
    load1, load5, load15 = 0.0, 0.0, 0.0
    runnable, total_procs = 0, 0
    try:
        with open("/proc/loadavg", "r") as f:
            parts = f.read().strip().split()
            if len(parts) >= 4:
                load1 = float(parts[0])
                load5 = float(parts[1])
                load15 = float(parts[2])
                thread_parts = parts[3].split("/")
                if len(thread_parts) == 2:
                    runnable = int(thread_parts[0])
                    total_procs = int(thread_parts[1])
    except Exception:
        pass
    return load1, load5, load15, runnable, total_procs


def audit_cpu_burst(
    warn_load_per_core: float = 1.5,
    crit_load_per_core: float = 2.5,
    surge_threshold: float = 0.5,
) -> Dict[str, Any]:
    """Evaluates load surge and calculates dynamic worker concurrency recommendations."""
    cpu_cores = get_cpu_core_count()
    load1, load5, load15, runnable, total_procs = parse_loadavg()

    load_per_core_1m = round(load1 / cpu_cores, 2)
    load_per_core_15m = round(load15 / cpu_cores, 2)

    # Surge derivative: relative surge of 1m load over 15m baseline
    if load15 > 0.1:
        load_surge = round((load1 - load15) / load15, 2)
    else:
        load_surge = 0.0

    runnable_ratio = round(runnable / cpu_cores, 2)

    # Calculate recommended maximum concurrency
    if load_per_core_1m >= crit_load_per_core or runnable_ratio >= 3.0:
        status = "CRITICAL"
        healthy = False
        recommended_concurrency = max(1, cpu_cores // 16)  # Minimal fallback
    elif load_per_core_1m >= warn_load_per_core or load_surge >= surge_threshold:
        status = "WARNING"
        healthy = False
        recommended_concurrency = max(2, cpu_cores // 8)   # Throttled
    else:
        status = "HEALTHY"
        healthy = True
        recommended_concurrency = max(4, cpu_cores // 4)   # Normal throughput

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "logical_cpu_cores": cpu_cores,
            "load_1m": load1,
            "load_5m": load5,
            "load_15m": load15,
            "load_per_core_1m": load_per_core_1m,
            "load_per_core_15m": load_per_core_15m,
            "load_surge_derivative": load_surge,
            "runnable_entities": runnable,
            "total_entities": total_procs,
            "runnable_ratio": runnable_ratio,
            "recommended_concurrency": recommended_concurrency,
            "status": status,
            "healthy": healthy,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Load Derivative & CPU Saturation Burst Dampener (Pattern 51)"
    )
    parser.add_argument(
        "--warn-load-per-core",
        type=float,
        default=1.5,
        help="Warning threshold for 1m load per core (default: 1.5)",
    )
    parser.add_argument(
        "--crit-load-per-core",
        type=float,
        default=2.5,
        help="Critical threshold for 1m load per core (default: 2.5)",
    )
    parser.add_argument(
        "--surge-threshold",
        type=float,
        default=0.5,
        help="Warning threshold for load surge derivative (default: 0.5)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry to stdout",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit with code 0 if healthy, code 1 if CPU saturation detected",
    )

    args = parser.parse_args()
    report = audit_cpu_burst(
        warn_load_per_core=args.warn_load_per_core,
        crit_load_per_core=args.crit_load_per_core,
        surge_threshold=args.surge_threshold,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"Jev CPU Saturation Burst Dampener (Pattern 51) — {report['timestamp']}")
        print(f"  • Load Average: {s['load_1m']} (1m), {s['load_5m']} (5m), {s['load_15m']} (15m)")
        print(f"  • Load / Core: {s['load_per_core_1m']} (Surge: {s['load_surge_derivative']:+.2f}) on {s['logical_cpu_cores']} cores")
        print(f"  • Runnable Threads: {s['runnable_entities']} / {s['total_entities']} (Ratio: {s['runnable_ratio']})")
        print(f"  • Recommended Concurrency Cap: {s['recommended_concurrency']} parallel workers")
        print(f"  • Status: {s['status']}")

    if args.check and not report["summary"]["healthy"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
