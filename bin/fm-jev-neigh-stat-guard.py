#!/usr/bin/env python3
"""
bin/fm-jev-neigh-stat-guard.py - Host Network Neighbor Cache Table Stats & Resolution Stasis Guard (Pattern 212)

Audits Linux kernel IPv4 ARP and IPv6 Neighbor Discovery (ND) cache statistics across all CPU cores:
  - /proc/net/stat/arp_cache (IPv4 ARP per-CPU lookups, hits, res_failed, forced_gc_runs, table_fulls)
  - /proc/net/stat/ndisc_cache (IPv6 ND per-CPU lookups, hits, res_failed, forced_gc_runs, table_fulls)
  - /proc/sys/net/ipv4/neigh/default/gc_thresh1 (minimum entries before garbage collection starts)
  - /proc/sys/net/ipv4/neigh/default/gc_thresh2 (soft limit triggering synchronous garbage collection)
  - /proc/sys/net/ipv4/neigh/default/gc_thresh3 (hard ceiling triggering table_full drops and ENOBUFS)
  - /proc/sys/net/ipv4/neigh/default/gc_interval (periodic GC run interval, default 30s)
  - /proc/sys/net/ipv4/neigh/default/gc_stale_time (stale neighbor eviction interval, default 60s)

Detects neighbor table memory pressure (forced GC runs), packet drops from unresolved next-hops,
and table exhaustion (table_fulls) across multi-agent RPC networks, container bridges, and clinic gateways.

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


def parse_neigh_stat_file(path: str) -> Tuple[int, Dict[str, int]]:
    """
    Parses /proc/net/stat/arp_cache or /proc/net/stat/ndisc_cache.
    First line is header. Subsequent lines are per-CPU hexadecimal counters.
    Returns (current_entries, aggregated_metrics).
    """
    metrics: Dict[str, int] = {
        "allocs": 0,
        "destroys": 0,
        "hash_grows": 0,
        "lookups": 0,
        "hits": 0,
        "res_failed": 0,
        "rcv_probes_mcast": 0,
        "rcv_probes_ucast": 0,
        "periodic_gc_runs": 0,
        "forced_gc_runs": 0,
        "unresolved_discards": 0,
        "table_fulls": 0,
    }
    current_entries = 0

    if not os.path.exists(path):
        return current_entries, metrics

    try:
        with open(path, "r", encoding="utf-8") as f:
            header_line = f.readline().strip()
            if not header_line:
                return current_entries, metrics
            headers = header_line.split()

            for line in f:
                parts = line.strip().split()
                if len(parts) == len(headers):
                    row: Dict[str, int] = {}
                    for h, val_hex in zip(headers, parts):
                        try:
                            row[h] = int(val_hex, 16)
                        except ValueError:
                            row[h] = 0

                    if "entries" in row and row["entries"] > current_entries:
                        current_entries = row["entries"]

                    for k in metrics.keys():
                        if k in row:
                            metrics[k] += row[k]
    except Exception:
        pass

    return current_entries, metrics


def audit_neigh_stat_guard(
    proc_arp_cache: str = "/proc/net/stat/arp_cache",
    proc_ndisc_cache: str = "/proc/net/stat/ndisc_cache",
    proc_sys_neigh: str = "/proc/sys/net/ipv4/neigh/default",
) -> Dict[str, Any]:
    arp_entries, arp_metrics = parse_neigh_stat_file(proc_arp_cache)
    ndisc_entries, ndisc_metrics = parse_neigh_stat_file(proc_ndisc_cache)

    gc_thresh1 = read_sysctl_int(os.path.join(proc_sys_neigh, "gc_thresh1"), 128)
    gc_thresh2 = read_sysctl_int(os.path.join(proc_sys_neigh, "gc_thresh2"), 512)
    gc_thresh3 = read_sysctl_int(os.path.join(proc_sys_neigh, "gc_thresh3"), 1024)
    gc_interval = read_sysctl_int(os.path.join(proc_sys_neigh, "gc_interval"), 30)
    gc_stale_time = read_sysctl_int(os.path.join(proc_sys_neigh, "gc_stale_time"), 60)

    total_entries = arp_entries + ndisc_entries
    arp_lookups = arp_metrics["lookups"]
    arp_hits = arp_metrics["hits"]
    arp_hit_ratio = round(arp_hits / arp_lookups, 4) if arp_lookups > 0 else 1.0

    forced_gc_runs = arp_metrics["forced_gc_runs"] + ndisc_metrics["forced_gc_runs"]
    table_fulls = arp_metrics["table_fulls"] + ndisc_metrics["table_fulls"]
    unresolved_discards = arp_metrics["unresolved_discards"] + ndisc_metrics["unresolved_discards"]
    res_failed = arp_metrics["res_failed"] + ndisc_metrics["res_failed"]

    saturation_ratio = 0.0
    if gc_thresh3 > 0:
        saturation_ratio = round(arp_entries / gc_thresh3, 4)

    issues: List[str] = []
    status = "HEALTHY"

    # Evaluation rules
    if table_fulls > 0:
        status = "CRITICAL"
        issues.append(
            f"CRITICAL: Neighbor table full drops detected ({table_fulls:,} table_full events). "
            f"Active entries: {arp_entries}/{gc_thresh3}. Outbound packets failing with ENOBUFS."
        )
    elif arp_entries >= gc_thresh3 and gc_thresh3 > 0:
        status = "CRITICAL"
        issues.append(
            f"CRITICAL: IPv4 ARP table reached hard ceiling gc_thresh3 "
            f"({arp_entries}/{gc_thresh3}, {saturation_ratio * 100:.1f}% saturation)."
        )

    if forced_gc_runs > 0:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"WARNING: Neighbor cache memory pressure detected ({forced_gc_runs:,} forced GC runs). "
            f"Table size exceeded gc_thresh2 ({gc_thresh2})."
        )

    if saturation_ratio >= 0.75:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"WARNING: High ARP table saturation ({arp_entries}/{gc_thresh3}, {saturation_ratio * 100:.1f}% saturation)."
        )

    if arp_lookups > 1000 and arp_hit_ratio < 0.50:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"WARNING: Low ARP cache hit ratio ({arp_hit_ratio * 100:.1f}%, {arp_hits:,} hits / {arp_lookups:,} lookups)."
        )

    recommendation = (
        "Neighbor cache table allocation, resolution hit ratio, and garbage collection are nominal."
        if status == "HEALTHY"
        else "Tune net.ipv4.neigh.default.gc_thresh3 and prune stale neighbor entries to prevent packet drops."
    )

    now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()

    return {
        "timestamp": now_iso,
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "arp_entries": arp_entries,
            "ndisc_entries": ndisc_entries,
            "total_entries": total_entries,
            "arp_lookups": arp_lookups,
            "arp_hits": arp_hits,
            "arp_hit_ratio": arp_hit_ratio,
            "arp_saturation_ratio": saturation_ratio,
            "forced_gc_runs": forced_gc_runs,
            "unresolved_discards": unresolved_discards,
            "table_fulls": table_fulls,
            "res_failed": res_failed,
            "gc_thresh1": gc_thresh1,
            "gc_thresh2": gc_thresh2,
            "gc_thresh3": gc_thresh3,
            "issues": issues,
            "recommendation": recommendation,
        },
        "arp_metrics": arp_metrics,
        "ndisc_metrics": ndisc_metrics,
        "sysctls": {
            "gc_thresh1": gc_thresh1,
            "gc_thresh2": gc_thresh2,
            "gc_thresh3": gc_thresh3,
            "gc_interval": gc_interval,
            "gc_stale_time": gc_stale_time,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network Neighbor Cache Table Stats & Resolution Stasis Guard (Pattern 212)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results as JSON")
    parser.add_argument("--verbose", "-v", action="store_true", help="Print verbose metrics")
    parser.add_argument("--warn-only", action="store_true", help="Exit 0 even on CRITICAL issues")
    parser.add_argument("--path-arp-cache", default="/proc/net/stat/arp_cache", help="Path to /proc/net/stat/arp_cache")
    parser.add_argument("--path-ndisc-cache", default="/proc/net/stat/ndisc_cache", help="Path to /proc/net/stat/ndisc_cache")
    parser.add_argument("--path-sysctl-neigh", default="/proc/sys/net/ipv4/neigh/default", help="Path to /proc/sys/net/ipv4/neigh/default")

    args = parser.parse_args()

    data = audit_neigh_stat_guard(
        proc_arp_cache=args.path_arp_cache,
        proc_ndisc_cache=args.path_ndisc_cache,
        proc_sys_neigh=args.path_sysctl_neigh,
    )

    if args.json:
        print(json.dumps(data, indent=2))
        return 0 if (data["summary"]["healthy"] or args.warn_only) else 1

    summary = data["summary"]
    status = summary["status"]

    color_code = "\033[32m" if status == "HEALTHY" else ("\033[33m" if status == "WARNING" else "\033[31m")
    reset_code = "\033[0m"

    print(f"[{color_code}{status}{reset_code}] Host Neighbor Table Cache Stats Guard (Pattern 212)")
    print(f"  IPv4 ARP Table Entries   : {summary['arp_entries']:,} / {summary['gc_thresh3']} limit ({summary['arp_saturation_ratio'] * 100:.1f}% saturation)")
    print(f"  IPv6 ND Table Entries    : {summary['ndisc_entries']:,}")
    print(f"  ARP Lookups / Hits       : {summary['arp_lookups']:,} lookups, {summary['arp_hits']:,} hits ({summary['arp_hit_ratio'] * 100:.1f}% hit ratio)")
    print(f"  Resolution Failures      : {summary['res_failed']:,}")
    print(f"  Forced GC Runs           : {summary['forced_gc_runs']:,} (gc_thresh2: {summary['gc_thresh2']})")
    print(f"  Unresolved Discards      : {summary['unresolved_discards']:,}")
    print(f"  Table Full Events        : {summary['table_fulls']:,}")

    if args.verbose:
        print("\n  IPv4 ARP Cache Detailed Metrics:")
        for k, v in data["arp_metrics"].items():
            print(f"    - {k:<22}: {v:,}")
        print("\n  IPv6 NDISC Cache Detailed Metrics:")
        for k, v in data["ndisc_metrics"].items():
            print(f"    - {k:<22}: {v:,}")

    if summary["issues"]:
        print("\n  Issues Detected:")
        for issue in summary["issues"]:
            print(f"    - {issue}")

    print(f"\n  Recommendation: {summary['recommendation']}")

    return 0 if (summary["healthy"] or args.warn_only) else 1


if __name__ == "__main__":
    sys.exit(main())
