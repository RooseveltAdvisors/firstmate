#!/usr/bin/env python3
"""
bin/fm-jev-conntrack-guard.py - Host Network Netfilter Connection Tracking & Routing Cache Guard (Pattern 207)

Audits Linux kernel Netfilter connection tracking (nf_conntrack) and IP routing cache (rt_cache) statistics:
  - /proc/sys/net/netfilter/nf_conntrack_count (active bidirectional flows tracked in kernel table)
  - /proc/sys/net/netfilter/nf_conntrack_max (maximum capacity before kernel drops packets)
  - /proc/sys/net/netfilter/nf_conntrack_buckets (hash table bucket count)
  - /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established (flow expiration timeout)
  - /proc/net/stat/rt_cache (per-CPU routing cache, martian packets, destination cache overflows)

Detects connection tracking table saturation, bucket collision chain bloat, unroutable packet storms,
and destination cache overflow stalls across multi-agent RPC tunnels, containers, and web scrapers.

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
    totals = {
        "entries": 0,
        "in_hit": 0,
        "in_slow_tot": 0,
        "in_no_route": 0,
        "in_martian_dst": 0,
        "in_martian_src": 0,
        "out_hit": 0,
        "out_slow_tot": 0,
        "gc_total": 0,
        "gc_dst_overflow": 0,
    }
    if not os.path.exists(path):
        return totals

    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = [line.strip() for line in f if line.strip()]
        if len(lines) <= 1:
            return totals

        header = lines[0].split()
        col_map = {name: idx for idx, name in enumerate(header)}

        for line in lines[1:]:
            parts = line.split()
            if len(parts) != len(header):
                continue
            for key in totals.keys():
                if key in col_map and col_map[key] < len(parts):
                    try:
                        totals[key] += int(parts[col_map[key]], 16)
                    except ValueError:
                        pass
    except Exception:
        pass

    return totals


def audit_conntrack(
    proc_sys_netfilter: str = "/proc/sys/net/netfilter",
    proc_rt_cache: str = "/proc/net/stat/rt_cache",
) -> Dict[str, Any]:
    count = read_sysctl_int(os.path.join(proc_sys_netfilter, "nf_conntrack_count"), -1)
    max_entries = read_sysctl_int(os.path.join(proc_sys_netfilter, "nf_conntrack_max"), -1)
    buckets = read_sysctl_int(os.path.join(proc_sys_netfilter, "nf_conntrack_buckets"), -1)
    tcp_established = read_sysctl_int(
        os.path.join(proc_sys_netfilter, "nf_conntrack_tcp_timeout_established"), -1
    )
    tcp_close_wait = read_sysctl_int(
        os.path.join(proc_sys_netfilter, "nf_conntrack_tcp_timeout_close_wait"), -1
    )
    tcp_time_wait = read_sysctl_int(
        os.path.join(proc_sys_netfilter, "nf_conntrack_tcp_timeout_time_wait"), -1
    )

    rt_stats = parse_rt_cache_stats(proc_rt_cache)

    issues: List[str] = []
    status = "HEALTHY"

    sat_ratio = 0.0
    if count >= 0 and max_entries > 0:
        sat_ratio = round(count / max_entries, 6)
        if sat_ratio >= 0.85:
            issues.append(
                f"CRITICAL: Netfilter conntrack table critically saturated ({count:,}/{max_entries:,}, {sat_ratio * 100:.2f}%); imminent packet dropping"
            )
            status = "CRITICAL"
        elif sat_ratio >= 0.65:
            issues.append(
                f"WARNING: Netfilter conntrack table elevated ({count:,}/{max_entries:,}, {sat_ratio * 100:.2f}%)"
            )
            status = "WARNING"

    chain_ratio = 0.0
    if count >= 0 and buckets > 0:
        chain_ratio = round(count / buckets, 4)
        if chain_ratio >= 2.5:
            issues.append(
                f"WARNING: Conntrack hash chain depth high ({count:,} entries across {buckets:,} buckets, avg chain {chain_ratio:.2f})"
            )
            if status != "CRITICAL":
                status = "WARNING"

    if rt_stats["gc_dst_overflow"] > 0:
        issues.append(
            f"CRITICAL: Routing destination cache overflow detected ({rt_stats['gc_dst_overflow']} overflows)"
        )
        status = "CRITICAL"

    if rt_stats["in_no_route"] > 50_000_000:
        issues.append(
            f"WARNING: High volume of unroutable ingress packets ({rt_stats['in_no_route']:,} no-route events)"
        )
        if status != "CRITICAL":
            status = "WARNING"

    healthy = status == "HEALTHY"
    recommendation = (
        "Netfilter connection tracking capacity, hash buckets, and routing cache are nominal."
        if healthy
        else "; ".join(issues)
    )

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "conntrack_count": count,
            "conntrack_max": max_entries,
            "conntrack_buckets": buckets,
            "saturation_ratio": sat_ratio,
            "bucket_chain_ratio": chain_ratio,
            "tcp_timeout_established_sec": tcp_established,
            "tcp_timeout_close_wait_sec": tcp_close_wait,
            "tcp_timeout_time_wait_sec": tcp_time_wait,
            "rt_cache_entries": rt_stats["entries"],
            "rt_in_no_route": rt_stats["in_no_route"],
            "rt_in_martian_dst": rt_stats["in_martian_dst"],
            "rt_in_martian_src": rt_stats["in_martian_src"],
            "rt_gc_dst_overflow": rt_stats["gc_dst_overflow"],
            "issues": issues,
            "recommendation": recommendation,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network Netfilter Connection Tracking & Routing Cache Guard (Pattern 207)"
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON telemetry")
    args = parser.parse_args()

    report = audit_conntrack()
    s = report["summary"]

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"[{s['status']}] Pattern 207: Host Network Netfilter Conntrack & Routing Cache Guard")
        print(
            f"  Conntrack Capacity: {s['conntrack_count']:,} / {s['conntrack_max']:,} entries "
            f"({s['saturation_ratio'] * 100:.2f}% saturation, buckets: {s['conntrack_buckets']:,}, avg chain: {s['bucket_chain_ratio']})"
        )
        print(
            f"  Timeouts: established={s['tcp_timeout_established_sec']}s, "
            f"close_wait={s['tcp_timeout_close_wait_sec']}s, time_wait={s['tcp_timeout_time_wait_sec']}s"
        )
        print(
            f"  Routing Cache: in_no_route={s['rt_in_no_route']:,}, "
            f"martian_dst={s['rt_in_martian_dst']:,}, dst_overflow={s['rt_gc_dst_overflow']:,}"
        )
        print(f"  Recommendation: {s['recommendation']}")

    return 0 if s["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
