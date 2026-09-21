#!/usr/bin/env python3
"""
fm-jev-softnet-guard.py - Jev Multi-Agent Network Softirq & Packet Processing Backlog Guard (Pattern 70)

Audits Linux kernel softnet packet processing across all CPU cores via /proc/net/softnet_stat.
Monitors input queue drops (netdev_max_backlog exhaustion), time squeeze events (NAPI budget exhaustion),
and CPU collisions to detect network frame drops and packet processing stalls before they disrupt
multi-agent SSE streaming, API polling, or clearinghouse connectivity.

Invariants:
  - Read-only diagnostics. Non-destructive.
  - Fail-open: graceful fallback if /proc/net/softnet_stat is missing or truncated.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_WARN_DROP_COUNT = 100
DEFAULT_WARN_SQUEEZE_COUNT = 50000
DEFAULT_WARN_COLLISION_COUNT = 100
SOFTNET_STAT_PATH = "/proc/net/softnet_stat"
NETDEV_MAX_BACKLOG_PATH = "/proc/sys/net/core/netdev_max_backlog"
NETDEV_BUDGET_PATH = "/proc/sys/net/core/netdev_budget"
NETDEV_BUDGET_USECS_PATH = "/proc/sys/net/core/netdev_budget_usecs"


def read_sysctl(path: str, default: int = 0) -> int:
    """Reads integer sysctl value."""
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r") as f:
            return int(f.read().strip())
    except Exception:
        return default


def parse_softnet_stat(path: str = SOFTNET_STAT_PATH) -> List[Dict[str, int]]:
    """Parses /proc/net/softnet_stat lines into structured per-core statistics."""
    cores: List[Dict[str, int]] = []
    if not os.path.exists(path):
        return cores

    try:
        with open(path, "r", errors="replace") as f:
            for core_id, line in enumerate(f):
                parts = line.strip().split()
                if len(parts) >= 3:
                    try:
                        processed = int(parts[0], 16)
                        dropped = int(parts[1], 16)
                        time_squeeze = int(parts[2], 16)
                        cpu_collision = int(parts[3], 16) if len(parts) > 3 else 0
                        received_rps = int(parts[4], 16) if len(parts) > 4 else 0
                        flow_limit = int(parts[5], 16) if len(parts) > 5 else 0

                        cores.append({
                            "core_id": core_id,
                            "processed": processed,
                            "dropped": dropped,
                            "time_squeeze": time_squeeze,
                            "cpu_collision": cpu_collision,
                            "received_rps": received_rps,
                            "flow_limit": flow_limit,
                        })
                    except ValueError:
                        pass
    except Exception:
        pass

    return cores


def audit_softnet(
    softnet_path: str = SOFTNET_STAT_PATH,
    max_backlog_path: str = NETDEV_MAX_BACKLOG_PATH,
    budget_path: str = NETDEV_BUDGET_PATH,
    budget_usecs_path: str = NETDEV_BUDGET_USECS_PATH,
    warn_drop_count: int = DEFAULT_WARN_DROP_COUNT,
    warn_squeeze_count: int = DEFAULT_WARN_SQUEEZE_COUNT,
    warn_collision_count: int = DEFAULT_WARN_COLLISION_COUNT,
) -> Dict[str, Any]:
    """Performs full fleet audit of network softnet backlog and NAPI budget."""
    cores = parse_softnet_stat(softnet_path)
    max_backlog = read_sysctl(max_backlog_path, default=1000)
    budget = read_sysctl(budget_path, default=300)
    budget_usecs = read_sysctl(budget_usecs_path, default=2000)

    total_cores = len(cores)
    total_processed = sum(c["processed"] for c in cores)
    total_dropped = sum(c["dropped"] for c in cores)
    total_squeeze = sum(c["time_squeeze"] for c in cores)
    total_collision = sum(c["cpu_collision"] for c in cores)

    drop_ratio = (total_dropped / total_processed) if total_processed > 0 else 0.0
    squeeze_ratio = (total_squeeze / total_processed) if total_processed > 0 else 0.0

    status = "HEALTHY"
    recommendation = "Kernel network softirq processing, backlog capacity, and NAPI budgets are nominal."

    if total_dropped > warn_drop_count or drop_ratio > 0.001:
        status = "CRITICAL"
        recommendation = (
            f"Active packet drop detected in network softnet backlog ({total_dropped:,} dropped packets, {drop_ratio*100:.3f}%). "
            f"Input queue exhausted (netdev_max_backlog={max_backlog}). Tune sysctl -w net.core.netdev_max_backlog=4096."
        )
    elif total_dropped > 0:
        status = "WARNING"
        recommendation = (
            f"Historic packet drops observed ({total_dropped:,} drops). "
            "Monitor network traffic bursts and consider increasing netdev_max_backlog."
        )
    elif total_squeeze > warn_squeeze_count:
        status = "WARNING"
        recommendation = (
            f"Elevated NAPI time squeeze events ({total_squeeze:,} events). "
            f"Cores exhausted processing budget ({budget} packets / {budget_usecs} usecs). Consider tuning net.core.netdev_budget=600."
        )
    elif total_collision > warn_collision_count:
        status = "WARNING"
        recommendation = (
            f"Elevated CPU device lock collisions ({total_collision:,} collisions). "
            "Inspect multi-queue NIC interrupt binding."
        )

    # Top squeezed or dropped cores
    hot_cores = sorted(cores, key=lambda c: (c["dropped"], c["time_squeeze"]), reverse=True)[:5]

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": (status == "HEALTHY"),
            "total_cores": total_cores,
            "total_processed": total_processed,
            "total_dropped": total_dropped,
            "drop_ratio": round(drop_ratio, 6),
            "total_squeeze": total_squeeze,
            "squeeze_ratio": round(squeeze_ratio, 6),
            "total_collision": total_collision,
            "netdev_max_backlog": max_backlog,
            "netdev_budget": budget,
            "netdev_budget_usecs": budget_usecs,
            "recommendation": recommendation,
        },
        "hot_cores": hot_cores,
        "cores": cores,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Network Softirq & Packet Processing Backlog Guard (Pattern 70)"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--verbose", action="store_true", help="Show all core breakdowns")
    parser.add_argument(
        "--warn-drop-count",
        type=int,
        default=DEFAULT_WARN_DROP_COUNT,
        help=f"Warn threshold for dropped packets (default: {DEFAULT_WARN_DROP_COUNT})",
    )
    parser.add_argument(
        "--warn-squeeze-count",
        type=int,
        default=DEFAULT_WARN_SQUEEZE_COUNT,
        help=f"Warn threshold for time squeeze events (default: {DEFAULT_WARN_SQUEEZE_COUNT})",
    )
    parser.add_argument(
        "--warn-collision-count",
        type=int,
        default=DEFAULT_WARN_COLLISION_COUNT,
        help=f"Warn threshold for CPU device lock collisions (default: {DEFAULT_WARN_COLLISION_COUNT})",
    )

    args = parser.parse_args()

    report = audit_softnet(
        warn_drop_count=args.warn_drop_count,
        warn_squeeze_count=args.warn_squeeze_count,
        warn_collision_count=args.warn_collision_count,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"[{s['status']}] Jev Network Softirq Backlog Guard (Pattern 70)")
        print(f"Cores: {s['total_cores']} | Processed: {s['total_processed']:,} packets | Dropped: {s['total_dropped']:,} ({s['drop_ratio']*100:.4f}%)")
        print(f"NAPI Squeeze: {s['total_squeeze']:,} events | Collisions: {s['total_collision']:,}")
        print(f"Sysctls: max_backlog={s['netdev_max_backlog']} | budget={s['netdev_budget']} ({s['netdev_budget_usecs']}us)")
        print(f"Status: {s['status']}")
        print(f"Recommendation: {s['recommendation']}")

        if args.verbose or s["total_dropped"] > 0 or s["total_squeeze"] > 0:
            print("\nTop Active/Squeezed Cores:")
            for c in report["hot_cores"][:4]:
                print(f"  Core {c['core_id']:2d}: {c['processed']:,} proc | {c['dropped']} drop | {c['time_squeeze']} squeeze | {c['cpu_collision']} coll")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
