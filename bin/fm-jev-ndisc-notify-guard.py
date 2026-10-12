#!/usr/bin/env python3
"""
bin/fm-jev-ndisc-notify-guard.py - Host Network IPv6 Neighbor Discovery Notification & Carrier Eviction Guard (Pattern 261)

Audits Linux kernel IPv6 Neighbor Discovery notification triggers, carrier loss eviction policies,
and NDISC resolution metrics:
  - conf/*/ndisc_notify: Unsolicited Neighbor Advertisement notification on link-up / address change (0=disabled, 1=enabled)
  - conf/*/ndisc_evict_nocarrier: Automatic eviction of NDISC cache entries on carrier down (0=keep, 1=evict)
  - conf/*/ndisc_tclass: DSCP / Traffic Class for Neighbor Discovery packets (default 0)
  - /proc/net/stat/ndisc_cache: NDISC cache statistics (lookups, hits, allocs, destroys, res_failed, forced_gc_runs, table_fulls)

Invariants:
  - Prevents dead route packet blackholes during carrier transitions.
  - Prevents unsolicited NA storms and spurious loopback emissions.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths or ndisc_cache stat files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

CONF_IPV6_BASE = "/proc/sys/net/ipv6/conf"
PROC_STAT_NDISC_CACHE = "/proc/net/stat/ndisc_cache"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content else default
    except (ValueError, OSError, IndexError):
        return default


def parse_ndisc_cache(path: str) -> Dict[str, int]:
    totals: Dict[str, int] = {
        "entries": 0,
        "allocs": 0,
        "destroys": 0,
        "lookups": 0,
        "hits": 0,
        "res_failed": 0,
        "forced_gc_runs": 0,
        "unresolved_discards": 0,
        "table_fulls": 0,
    }
    if not os.path.isfile(path):
        return totals

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = [line.strip() for line in f if line.strip()]
        if not lines:
            return totals
        headers = lines[0].split()
        for line in lines[1:]:
            parts = line.split()
            if len(parts) == len(headers):
                for h, v in zip(headers, parts):
                    if h in totals:
                        try:
                            totals[h] += int(v, 16)
                        except ValueError:
                            pass
    except OSError:
        pass
    return totals


def audit_ndisc_notify_guard(
    conf_dir: str = CONF_IPV6_BASE,
    ndisc_stat_path: str = PROC_STAT_NDISC_CACHE,
) -> Dict[str, Any]:
    all_notify: Dict[str, int] = {}
    all_evict: Dict[str, int] = {}
    all_tclass: Dict[str, int] = {}

    if os.path.isdir(conf_dir):
        for entry in os.listdir(conf_dir):
            iface_path = os.path.join(conf_dir, entry)
            if os.path.isdir(iface_path):
                ifname = entry
                notify_p = os.path.join(iface_path, "ndisc_notify")
                evict_p = os.path.join(iface_path, "ndisc_evict_nocarrier")
                tclass_p = os.path.join(iface_path, "ndisc_tclass")

                if os.path.isfile(notify_p):
                    all_notify[ifname] = read_sysctl_int(notify_p)
                if os.path.isfile(evict_p):
                    all_evict[ifname] = read_sysctl_int(evict_p)
                if os.path.isfile(tclass_p):
                    all_tclass[ifname] = read_sysctl_int(tclass_p)

    ndisc_stats = parse_ndisc_cache(ndisc_stat_path)
    lookups = ndisc_stats.get("lookups", 0)
    hits = ndisc_stats.get("hits", 0)
    res_failed = ndisc_stats.get("res_failed", 0)
    forced_gc_runs = ndisc_stats.get("forced_gc_runs", 0)
    table_fulls = ndisc_stats.get("table_fulls", 0)

    issues: List[str] = []
    status = "HEALTHY"

    # Loopback must never have ndisc_notify enabled
    if all_notify.get("lo", 0) == 1:
        issues.append(
            "Loopback interface has ndisc_notify enabled (ndisc_notify=1 on lo); "
            "risk of spurious unsolicited NA on loopback"
        )
        status = "WARNING"

    # Check for interfaces where carrier eviction is disabled (0)
    disabled_evict: List[str] = []
    for ifname, val in all_evict.items():
        if ifname not in ("lo",) and val == 0:
            disabled_evict.append(ifname)

    if disabled_evict:
        issues.append(
            f"NDISC carrier loss eviction disabled on interfaces: {', '.join(disabled_evict)} "
            "(risk of stale neighbor blackholes upon linkdown)"
        )
        if status != "CRITICAL":
            status = "WARNING"

    # Check for invalid tclass
    for ifname, val in all_tclass.items():
        if val < 0 or val > 255:
            issues.append(f"Invalid ndisc_tclass value {val} on interface {ifname} (must be 0..255)")
            if status != "CRITICAL":
                status = "WARNING"

    # Table full / forced GC checks
    if table_fulls > 0:
        issues.append(f"NDISC table overflow: {table_fulls} table_full events")
        status = "CRITICAL"
    elif forced_gc_runs > 0:
        issues.append(f"NDISC forced garbage collection active: {forced_gc_runs} runs")
        if status != "CRITICAL":
            status = "WARNING"

    return {
        "pattern": 261,
        "name": "ndisc_notify",
        "description": "Host Network IPv6 Neighbor Discovery Notification & Carrier Eviction Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.timezone.utc and datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "interfaces_audited": len(all_notify),
        "lo_ndisc_notify": all_notify.get("lo", 0),
        "all_ndisc_notify": all_notify.get("all", 0),
        "default_ndisc_evict_nocarrier": all_evict.get("default", 1),
        "all_ndisc_evict_nocarrier": all_evict.get("all", 1),
        "ndisc_lookups": lookups,
        "ndisc_hits": hits,
        "res_failed": res_failed,
        "forced_gc_runs": forced_gc_runs,
        "table_fulls": table_fulls,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Host Network IPv6 Neighbor Discovery Notification & Carrier Eviction Guard (Pattern 261)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    parser.add_argument("--conf-dir", default=CONF_IPV6_BASE, help="Path to /proc/sys/net/ipv6/conf directory")
    parser.add_argument("--ndisc-stat-file", default=PROC_STAT_NDISC_CACHE, help="Path to /proc/net/stat/ndisc_cache")

    args = parser.parse_args()

    report = audit_ndisc_notify_guard(
        conf_dir=args.conf_dir,
        ndisc_stat_path=args.ndisc_stat_file,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Pattern 261: {report['name']} - Status: {report['status']}")
        print(f"  interfaces_audited: {report['interfaces_audited']}")
        print(f"  lo_ndisc_notify: {report['lo_ndisc_notify']}")
        print(f"  all_ndisc_notify: {report['all_ndisc_notify']}")
        print(f"  default_ndisc_evict_nocarrier: {report['default_ndisc_evict_nocarrier']}")
        print(f"  all_ndisc_evict_nocarrier: {report['all_ndisc_evict_nocarrier']}")
        print(f"  ndisc_lookups: {report['ndisc_lookups']}")
        print(f"  ndisc_hits: {report['ndisc_hits']}")
        print(f"  res_failed: {report['res_failed']}")
        print(f"  forced_gc_runs: {report['forced_gc_runs']}")
        print(f"  table_fulls: {report['table_fulls']}")
        if report["issues"]:
            print("  Issues:")
            for issue in report["issues"]:
                print(f"    - {issue}")
        else:
            print("  Issues: none (nominal)")

    return 0 if report["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
