#!/usr/bin/env python3
"""
fm-jev-numa-guard.py - Jev Multi-Agent Core CPU Affinity & NUMA Node Memory Allocation Guard (Pattern 83)

Audits Linux kernel NUMA node memory allocation statistics (/sys/devices/system/node/node*/numastat),
cross-node memory latency penalties (numa_miss, numa_foreign), and multi-agent CPU core affinity masks
(os.sched_getaffinity) to prevent cross-socket interconnect saturation and CPU starvation during high-concurrency
builds, test matrix shards, and inference workloads.

Invariants:
  - Read-only diagnostics. Non-destructive.
  - Fail-open: graceful fallback on single-node or non-NUMA systems.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

DEFAULT_WARN_NUMA_MISS_PCT = 5.0
DEFAULT_CRIT_NUMA_MISS_PCT = 20.0

SYS_NODE_DIR = "/sys/devices/system/node"


def parse_numastat(stat_path: str) -> Dict[str, int]:
    """Parses /sys/devices/system/node/nodeX/numastat key-value metrics."""
    metrics: Dict[str, int] = {}
    if not os.path.exists(stat_path):
        return metrics
    try:
        with open(stat_path, "r") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 2:
                    try:
                        metrics[parts[0]] = int(parts[1])
                    except ValueError:
                        pass
    except Exception:
        pass
    return metrics


def get_cpu_affinity() -> List[int]:
    """Gets CPU affinity mask for current process."""
    if hasattr(os, "sched_getaffinity"):
        try:
            return sorted(list(os.sched_getaffinity(0)))
        except Exception:
            pass
    return list(range(os.cpu_count() or 1))


def audit_numa(
    node_dir: str = SYS_NODE_DIR,
    warn_miss_pct: float = DEFAULT_WARN_NUMA_MISS_PCT,
    crit_miss_pct: float = DEFAULT_CRIT_NUMA_MISS_PCT,
) -> Dict[str, Any]:
    """Audits NUMA nodes and CPU affinity distribution."""
    nodes: Dict[str, Dict[str, Any]] = {}
    total_hit = 0
    total_miss = 0
    total_foreign = 0
    total_local = 0
    total_other = 0

    if os.path.exists(node_dir):
        try:
            for entry in sorted(os.listdir(node_dir)):
                if entry.startswith("node") and entry[4:].isdigit():
                    stat_file = os.path.join(node_dir, entry, "numastat")
                    stat = parse_numastat(stat_file)
                    if stat:
                        hit = stat.get("numa_hit", 0)
                        miss = stat.get("numa_miss", 0)
                        foreign = stat.get("numa_foreign", 0)
                        local = stat.get("local_node", 0)
                        other = stat.get("other_node", 0)

                        total_hit += hit
                        total_miss += miss
                        total_foreign += foreign
                        total_local += local
                        total_other += other

                        hit_miss_sum = hit + miss
                        miss_pct = round((miss / hit_miss_sum * 100.0), 2) if hit_miss_sum > 0 else 0.0

                        nodes[entry] = {
                            "numa_hit": hit,
                            "numa_miss": miss,
                            "numa_foreign": foreign,
                            "local_node": local,
                            "other_node": other,
                            "miss_pct": miss_pct,
                        }
        except Exception:
            pass

    overall_hit_miss = total_hit + total_miss
    overall_miss_pct = round((total_miss / overall_hit_miss * 100.0), 2) if overall_hit_miss > 0 else 0.0

    affinity_cpus = get_cpu_affinity()
    total_system_cpus = os.cpu_count() or len(affinity_cpus)
    affinity_pct = round((len(affinity_cpus) / total_system_cpus * 100.0), 2) if total_system_cpus > 0 else 100.0

    issues: List[str] = []
    status = "HEALTHY"

    if overall_miss_pct >= crit_miss_pct:
        status = "CRITICAL"
        issues.append(f"Severe NUMA memory allocation misses: {overall_miss_pct}% cross-node access")
    elif overall_miss_pct >= warn_miss_pct:
        status = "WARNING"
        issues.append(f"Elevated NUMA memory allocation misses: {overall_miss_pct}% cross-node access")

    if total_system_cpus > 4 and len(affinity_cpus) <= 1:
        if status == "HEALTHY":
            status = "WARNING"
        issues.append(f"Severely constrained CPU affinity: only {len(affinity_cpus)} of {total_system_cpus} cores available")

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "numa_nodes_count": len(nodes),
            "total_numa_hit": total_hit,
            "total_numa_miss": total_miss,
            "total_numa_foreign": total_foreign,
            "overall_miss_pct": overall_miss_pct,
            "total_cpus": total_system_cpus,
            "affinity_cpus_count": len(affinity_cpus),
            "affinity_pct": affinity_pct,
            "issues": issues,
        },
        "nodes": nodes,
        "affinity_cpus_sample": affinity_cpus[:8],
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Core CPU Affinity & NUMA Node Memory Allocation Guard (Pattern 83)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--warn-miss", type=float, default=DEFAULT_WARN_NUMA_MISS_PCT, help=f"Warning NUMA miss pct (default {DEFAULT_WARN_NUMA_MISS_PCT})")
    parser.add_argument("--crit-miss", type=float, default=DEFAULT_CRIT_NUMA_MISS_PCT, help=f"Critical NUMA miss pct (default {DEFAULT_CRIT_NUMA_MISS_PCT})")
    parser.add_argument("--sys-node-dir", type=str, default=SYS_NODE_DIR, help="Path to /sys/devices/system/node")

    args = parser.parse_args()

    result = audit_numa(
        node_dir=args.sys_node_dir,
        warn_miss_pct=args.warn_miss,
        crit_miss_pct=args.crit_miss,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else ("\033[31m" if summary["status"] == "CRITICAL" else "\033[33m")
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent CPU Affinity & NUMA Guard (Pattern 83)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    print(f" NUMA Nodes:             {summary['numa_nodes_count']} active node(s)")
    print(f" NUMA Miss Ratio:        {summary['overall_miss_pct']}% ({summary['total_numa_miss']:,} misses / {summary['total_numa_hit']:,} hits)")
    print(f" CPU Affinity:           {summary['affinity_cpus_count']} / {summary['total_cpus']} cores ({summary['affinity_pct']}%)")

    if result["nodes"]:
        print("\nPer-Node Details:")
        for name, n in result["nodes"].items():
            print(f"  - {name}: hits={n['numa_hit']:,}, misses={n['numa_miss']:,} ({n['miss_pct']}%), foreign={n['numa_foreign']:,}")

    if summary["issues"]:
        print("\nActive Issues:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nNo NUMA allocation misses, cross-socket penalties, or CPU affinity constraints detected.")
    print("================================================================================")


if __name__ == "__main__":
    main()
