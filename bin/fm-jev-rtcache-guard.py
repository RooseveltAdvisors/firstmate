#!/usr/bin/env python3
"""
bin/fm-jev-rtcache-guard.py - Host Network Routing Cache Exception & Martian Packet Drop Guard (Pattern 236)

Audits Linux kernel IPv4 routing cache, exception table, and garbage collection metrics from:
  - /proc/net/stat/rt_cache (per-CPU routing cache stats: entries, in_no_route, in_martian_src, in_martian_dst, gc_total, gc_dst_overflow)
  - /proc/sys/net/ipv4/route/max_size, gc_interval, gc_timeout, min_pmtu, mtu_expires

Detects routing cache exhaustion, FIB destination overflows, spoofed martian packet bursts,
and routing GC stalls before network communication across multi-agent clusters is interrupted.

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


def parse_rt_cache_stats(path: str = "/proc/net/stat/rt_cache") -> Dict[str, int]:
    totals: Dict[str, int] = {}
    if not os.path.exists(path):
        return totals
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = [line.strip().split() for line in f if line.strip()]
        if len(lines) < 2:
            return totals
        headers = lines[0]
        for h in headers:
            totals[h] = 0
        for row in lines[1:]:
            for h, v in zip(headers, row):
                try:
                    totals[h] += int(v, 16)
                except ValueError:
                    continue
    except Exception:
        pass
    return totals


def audit_rt_cache(
    proc_rt_cache: str = "/proc/net/stat/rt_cache",
    proc_sys_route: str = "/proc/sys/net/ipv4/route",
) -> Dict[str, Any]:
    stats = parse_rt_cache_stats(proc_rt_cache)

    max_size = read_sysctl_int(os.path.join(proc_sys_route, "max_size"), 2147483647)
    gc_interval = read_sysctl_int(os.path.join(proc_sys_route, "gc_interval"), 60)
    gc_timeout = read_sysctl_int(os.path.join(proc_sys_route, "gc_timeout"), 300)
    min_pmtu = read_sysctl_int(os.path.join(proc_sys_route, "min_pmtu"), 552)
    mtu_expires = read_sysctl_int(os.path.join(proc_sys_route, "mtu_expires"), 600)

    entries = stats.get("entries", 0)
    gc_total = stats.get("gc_total", 0)
    gc_goal_miss = stats.get("gc_goal_miss", 0)
    gc_dst_overflow = stats.get("gc_dst_overflow", 0)
    in_martian_src = stats.get("in_martian_src", 0)
    in_martian_dst = stats.get("in_martian_dst", 0)
    in_no_route = stats.get("in_no_route", 0)
    out_slow_tot = stats.get("out_slow_tot", 0)

    issues: List[str] = []
    if gc_dst_overflow > 0:
        issues.append(f"CRITICAL: routing cache destination overflow ({gc_dst_overflow} packets dropped)")
    if gc_goal_miss > 1000:
        issues.append(f"WARNING: elevated route GC goal misses ({gc_goal_miss} misses)")
    if in_martian_dst > 1000:
        issues.append(f"WARNING: elevated martian destination packets ({in_martian_dst} packets)")

    status = "CRITICAL" if gc_dst_overflow > 0 else ("WARNING" if issues else "HEALTHY")

    summary = {
        "status": status,
        "healthy": (status == "HEALTHY"),
        "entries": entries,
        "gc_total": gc_total,
        "gc_goal_miss": gc_goal_miss,
        "gc_dst_overflow": gc_dst_overflow,
        "in_martian_src": in_martian_src,
        "in_martian_dst": in_martian_dst,
        "in_no_route": in_no_route,
        "out_slow_tot": out_slow_tot,
        "max_size": max_size,
        "gc_interval_s": gc_interval,
        "gc_timeout_s": gc_timeout,
        "min_pmtu": min_pmtu,
        "mtu_expires_s": mtu_expires,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "stats": stats,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network Routing Cache Exception & Martian Packet Drop Guard (Pattern 202)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_rt_cache()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0 if report["summary"]["healthy"] else 1

    s = report["summary"]
    print("Routing Cache Exception & Martian Packet Guard (Pattern 236)")
    print(f"  Status:                 {s['status']}")
    print(f"  Active Route Entries:   {s['entries']:,}")
    print(f"  GC Overflow Drops:      {s['gc_dst_overflow']}")
    print(f"  GC Cycles:              {s['gc_total']}")
    print(f"  GC Goal Misses:         {s['gc_goal_miss']}")
    print(f"  Martian Source Packets: {s['in_martian_src']}")
    print(f"  Martian Dest Packets:   {s['in_martian_dst']}")
    print(f"  No Route Packets:       {s['in_no_route']:,}")
    print(f"  Outbound Lookups:       {s['out_slow_tot']:,}")
    print(f"  Routing gc_timeout:     {s['gc_timeout_s']}s (interval: {s['gc_interval_s']}s)")
    print(f"  Path MTU Expiration:    {s['mtu_expires_s']}s (min PMTU: {s['min_pmtu']} bytes)")

    if s["issues"]:
        print("\nIdentified Issues:")
        for iss in s["issues"]:
            print(f"  - {iss}")

    return 0 if s["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
