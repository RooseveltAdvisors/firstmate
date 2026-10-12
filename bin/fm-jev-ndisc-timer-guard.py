#!/usr/bin/env python3
"""
bin/fm-jev-ndisc-timer-guard.py - Host IPv6 Neighbor Discovery (NDISC) Reachability Timers & Resolution Guard (Pattern 268 / Pattern 406)

Audits Linux kernel IPv6 Neighbor Discovery timing parameters (RFC 4861 §6.3.2, §7.3),
solicitation bounds, queue limits, and resolution telemetry:
  - /proc/sys/net/ipv6/neigh/default/base_reachable_time_ms:
      Base reachable time in ms (RFC default: 30000ms; randomized ReachableTime factor: 0.5..1.5)
  - /proc/sys/net/ipv6/neigh/default/delay_first_probe_time:
      Delay in seconds before first unicast probe after neighbor enters DELAY state (RFC default: 5s)
  - /proc/sys/net/ipv6/neigh/default/retrans_time_ms:
      Retransmission interval in ms between Neighbor Solicitations (RFC default: 1000ms)
  - /proc/sys/net/ipv6/neigh/default/gc_stale_time:
      Interval in seconds before STALE neighbor entries are verified or evicted (default: 60s)
  - /proc/sys/net/ipv6/neigh/default/mcast_solicit:
      Maximum multicast solicitations sent before failure (RFC 4861 default: 3)
  - /proc/sys/net/ipv6/neigh/default/ucast_solicit:
      Maximum unicast probes sent before declaring neighbor unreachable (RFC 4861 default: 3)
  - /proc/sys/net/ipv6/neigh/default/unres_qlen:
      Maximum queue length for packets waiting for address resolution (default: 101)
  - /proc/sys/net/ipv6/neigh/default/unres_qlen_bytes:
      Maximum bytes allocated for unresolved packet queue (default: 212992)
  - /proc/net/stat/ndisc_cache:
      Per-CPU neighbor table lookups, hits, resolution failures, probe receptions,
      periodic GC runs, forced GC runs, unresolved discards, and table full errors.

Invariants:
  - base_reachable_time_ms must be within safe bounds [1000, 3600000].
  - delay_first_probe_time must be within safe bounds [1, 60].
  - retrans_time_ms must be within safe bounds [100, 60000].
  - mcast_solicit >= 1 and ucast_solicit >= 1.
  - Table full drops and forced GC runs indicate neighbor exhaustion and trigger alerts.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths or stat file are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Tuple

PROC_SYS_NEIGH6_DEFAULT = "/proc/sys/net/ipv6/neigh/default"
PROC_NET_STAT_NDISC = "/proc/net/stat/ndisc_cache"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content else default
    except (ValueError, OSError, IndexError):
        return default


def parse_ndisc_cache_stat(path: str) -> Tuple[int, Dict[str, int]]:
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

    if not os.path.isfile(path):
        return current_entries, metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        if not lines:
            return current_entries, metrics
        headers = lines[0].strip().split()

        for line in lines[1:]:
            parts = line.strip().split()
            if len(parts) == len(headers):
                for h, val_hex in zip(headers, parts):
                    try:
                        val = int(val_hex, 16)
                        if h == "entries":
                            current_entries = max(current_entries, val)
                        elif h in metrics:
                            metrics[h] += val
                    except ValueError:
                        pass
    except OSError:
        pass

    return current_entries, metrics


def audit_ndisc_timer_guard(
    neigh_dir: str = PROC_SYS_NEIGH6_DEFAULT,
    stat_path: str = PROC_NET_STAT_NDISC,
) -> Dict[str, Any]:
    issues: List[str] = []
    status = "HEALTHY"

    base_reachable_ms = read_sysctl_int(os.path.join(neigh_dir, "base_reachable_time_ms"), 30000)
    delay_first_probe = read_sysctl_int(os.path.join(neigh_dir, "delay_first_probe_time"), 5)
    retrans_ms = read_sysctl_int(os.path.join(neigh_dir, "retrans_time_ms"), 1000)
    gc_stale_time = read_sysctl_int(os.path.join(neigh_dir, "gc_stale_time"), 60)
    mcast_solicit = read_sysctl_int(os.path.join(neigh_dir, "mcast_solicit"), 3)
    ucast_solicit = read_sysctl_int(os.path.join(neigh_dir, "ucast_solicit"), 3)
    unres_qlen = read_sysctl_int(os.path.join(neigh_dir, "unres_qlen"), 101)
    unres_qlen_bytes = read_sysctl_int(os.path.join(neigh_dir, "unres_qlen_bytes"), 212992)

    if base_reachable_ms < 1000 or base_reachable_ms > 3600000:
        issues.append(
            f"base_reachable_time_ms={base_reachable_ms} outside safe bounds [1000, 3600000]"
        )
        status = "WARNING"

    if delay_first_probe < 1 or delay_first_probe > 60:
        issues.append(
            f"delay_first_probe_time={delay_first_probe} outside safe bounds [1, 60]"
        )
        status = "WARNING"

    if retrans_ms < 100 or retrans_ms > 60000:
        issues.append(
            f"retrans_time_ms={retrans_ms} outside safe bounds [100, 60000]"
        )
        status = "WARNING"

    if mcast_solicit < 1:
        issues.append(f"mcast_solicit={mcast_solicit} < 1 (risk of neighbor discovery failure)")
        status = "WARNING"

    if ucast_solicit < 1:
        issues.append(f"ucast_solicit={ucast_solicit} < 1 (risk of premature reachability failure)")
        status = "WARNING"

    if unres_qlen < 1:
        issues.append(f"unres_qlen={unres_qlen} < 1 (packets waiting for resolution will be dropped immediately)")
        status = "WARNING"

    current_entries, stats = parse_ndisc_cache_stat(stat_path)

    forced_gc = stats.get("forced_gc_runs", 0)
    table_fulls = stats.get("table_fulls", 0)
    unres_discards = stats.get("unresolved_discards", 0)
    res_failed = stats.get("res_failed", 0)

    if table_fulls > 0:
        issues.append(f"IPv6 neighbor table full errors detected: {table_fulls}")
        status = "CRITICAL"

    if forced_gc > 0:
        issues.append(f"Forced neighbor GC runs under memory pressure detected: {forced_gc}")
        if status != "CRITICAL":
            status = "WARNING"

    if unres_discards > 0:
        issues.append(f"Unresolved packet queue discards detected: {unres_discards}")
        if status != "CRITICAL":
            status = "WARNING"

    return {
        "pattern": 268,
        "name": "ndisc_timer",
        "description": "Host IPv6 Neighbor Discovery (NDISC) Reachability Timers & Resolution Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.timezone.utc and datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "base_reachable_time_ms": base_reachable_ms,
        "delay_first_probe_time": delay_first_probe,
        "retrans_time_ms": retrans_ms,
        "gc_stale_time": gc_stale_time,
        "mcast_solicit": mcast_solicit,
        "ucast_solicit": ucast_solicit,
        "unres_qlen": unres_qlen,
        "unres_qlen_bytes": unres_qlen_bytes,
        "current_entries": current_entries,
        "lookups": stats.get("lookups", 0),
        "hits": stats.get("hits", 0),
        "res_failed": res_failed,
        "forced_gc_runs": forced_gc,
        "table_fulls": table_fulls,
        "unresolved_discards": unres_discards,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Host IPv6 Neighbor Discovery (NDISC) Reachability Timers & Resolution Guard (Pattern 268 / Pattern 406)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    parser.add_argument("--neigh-dir", default=PROC_SYS_NEIGH6_DEFAULT, help="Path to /proc/sys/net/ipv6/neigh/default directory")
    parser.add_argument("--stat-file", default=PROC_NET_STAT_NDISC, help="Path to /proc/net/stat/ndisc_cache")

    args = parser.parse_args()

    report = audit_ndisc_timer_guard(
        neigh_dir=args.neigh_dir,
        stat_path=args.stat_file,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Pattern 268: {report['name']} - Status: {report['status']}")
        print(f"  base_reachable_time_ms: {report['base_reachable_time_ms']}, delay_first_probe_time: {report['delay_first_probe_time']}s, retrans_time_ms: {report['retrans_time_ms']}")
        print(f"  solicitations: mcast={report['mcast_solicit']}, ucast={report['ucast_solicit']}, unres_qlen={report['unres_qlen']} ({report['unres_qlen_bytes']} bytes)")
        print(f"  cache: entries={report['current_entries']}, lookups={report['lookups']}, hits={report['hits']}, res_failed={report['res_failed']}")
        print(f"  pressure: forced_gc={report['forced_gc_runs']}, table_fulls={report['table_fulls']}, unres_discards={report['unresolved_discards']}")
        if report["issues"]:
            print("  Issues:")
            for issue in report["issues"]:
                print(f"    - {issue}")
        else:
            print("  Issues: none (nominal)")

    return 0 if report["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
