#!/usr/bin/env python3
"""
bin/fm-jev-rt6-stats-guard.py - Host Network IPv6 Route Table & FIB6 Garbage Collection Guard (Pattern 239)

Audits Linux kernel IPv6 Forwarding Information Base (FIB6) route table statistics and GC parameters from:
  - /proc/net/rt6_stats (fib6_nodes, fib6_route_nodes, fib6_rt_alloc, fib6_rt_entries, fib6_rt_cache, fib6_rt_garbage)
  - /proc/sys/net/ipv6/route/ (gc_thresh, max_size, gc_interval, gc_timeout, min_adv_mss, mtu_expires)

Detects IPv6 route table exhaustion, FIB6 garbage collection backlogs, and memory bloat across
multi-agent dual-stack mesh topologies and container networking bridges.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysfs/procfs files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Tuple


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception:
        return default


def parse_rt6_stats(path: str = "/proc/net/rt6_stats") -> Dict[str, int]:
    keys = [
        "fib6_nodes",
        "fib6_route_nodes",
        "fib6_rt_alloc",
        "fib6_rt_entries",
        "fib6_rt_cache",
        "fib6_rt_garbage",
        "fib6_rt_total",
    ]
    result: Dict[str, int] = {k: 0 for k in keys}
    if not os.path.exists(path):
        return result
    try:
        with open(path, "r", encoding="utf-8") as f:
            parts = f.read().strip().split()
        for k, v_hex in zip(keys, parts):
            try:
                result[k] = int(v_hex, 16)
            except ValueError:
                continue
    except Exception:
        pass
    return result


def audit_rt6_stats(
    rt6_stats_path: str = "/proc/net/rt6_stats",
    sys_route6_path: str = "/proc/sys/net/ipv6/route",
) -> Dict[str, Any]:
    stats = parse_rt6_stats(rt6_stats_path)

    gc_thresh = read_sysctl_int(os.path.join(sys_route6_path, "gc_thresh"), 1024)
    max_size = read_sysctl_int(os.path.join(sys_route6_path, "max_size"), 2147483647)
    gc_interval = read_sysctl_int(os.path.join(sys_route6_path, "gc_interval"), 30)
    gc_timeout = read_sysctl_int(os.path.join(sys_route6_path, "gc_timeout"), 60)
    min_adv_mss = read_sysctl_int(os.path.join(sys_route6_path, "min_adv_mss"), 1220)
    mtu_expires = read_sysctl_int(os.path.join(sys_route6_path, "mtu_expires"), 600)

    nodes = stats.get("fib6_nodes", 0)
    route_nodes = stats.get("fib6_route_nodes", 0)
    alloc = stats.get("fib6_rt_alloc", 0)
    entries = stats.get("fib6_rt_entries", 0)
    cache = stats.get("fib6_rt_cache", 0)
    garbage = stats.get("fib6_rt_garbage", 0)

    issues: List[str] = []
    recommendations: List[str] = []

    if max_size > 0 and entries >= max_size:
        issues.append(f"CRITICAL: IPv6 route table reached max_size ({entries} >= {max_size})")
        recommendations.append("Increase net.ipv6.route.max_size or prune stale IPv6 route entries")

    if garbage > 500:
        issues.append(f"Elevated FIB6 garbage queue backlog: {garbage} routes (> 500)")
        recommendations.append("Decrease net.ipv6.route.gc_interval or audit high route churn")

    if gc_thresh > 0 and entries > (gc_thresh * 2):
        issues.append(f"IPv6 route table entries heavily exceed gc_thresh: {entries} > {gc_thresh * 2}")
        recommendations.append("Tune net.ipv6.route.gc_thresh to match network topology density")

    if entries >= max_size and max_size > 0:
        status = "CRITICAL"
    elif issues:
        status = "WARNING"
    else:
        status = "HEALTHY"
        recommendations.append(
            "IPv6 route table capacity, FIB6 nodes, and GC garbage queue are nominal"
        )

    summary = {
        "status": status,
        "healthy": (status == "HEALTHY"),
        "fib6_nodes": nodes,
        "fib6_route_nodes": route_nodes,
        "fib6_rt_alloc": alloc,
        "fib6_rt_entries": entries,
        "fib6_rt_cache": cache,
        "fib6_rt_garbage": garbage,
        "gc_thresh": gc_thresh,
        "max_size": max_size,
        "gc_interval_s": gc_interval,
        "gc_timeout_s": gc_timeout,
        "min_adv_mss": min_adv_mss,
        "mtu_expires_s": mtu_expires,
        "issues": issues,
        "recommendation": recommendations[0],
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "stats": stats,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IPv6 Route Table & FIB6 Garbage Collection Guard (Pattern 239)"
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON telemetry")
    args = parser.parse_args()

    report = audit_rt6_stats()
    s = report["summary"]

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"[{s['status']}] Pattern 239: Host Network IPv6 Route Table & FIB6 Guard")
        print(
            f"  FIB6 Nodes: {s['fib6_nodes']} nodes, {s['fib6_route_nodes']} route nodes, "
            f"{s['fib6_rt_entries']} route entries (alloc: {s['fib6_rt_alloc']:,})"
        )
        print(
            f"  FIB6 GC: {s['fib6_rt_garbage']} garbage queue, gc_thresh={s['gc_thresh']}, "
            f"max_size={s['max_size']:,} (gc_interval: {s['gc_interval_s']}s)"
        )
        print(f"  Recommendation: {s['recommendation']}")

    return 0 if s["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
