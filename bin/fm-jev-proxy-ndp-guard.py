#!/usr/bin/env python3
"""
bin/fm-jev-proxy-ndp-guard.py - Host IPv6 Proxy Neighbor Discovery (Proxy NDP / RFC 4389) Guard (Pattern 259)

Audits Linux kernel RFC 4389 IPv6 Neighbor Discovery Proxy configuration and NDISC table metrics:
  - conf/*/proxy_ndp: Per-interface proxy NDP enablement (0=disabled, 1=enabled).
  - ndisc_cache: NDISC cache statistics (lookups, hits, res_failed, forced_gc_runs, unresolved_discards, table_fulls).

Invariants:
  - Prevents unintended proxy Neighbor Advertisements and cross-subnet IPv6 address spoofing.
  - Ensures RFC 4389 containment across multi-agent cluster interfaces.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths or stat files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import glob
import json
import os
import sys
from typing import Any, Dict, List

CONF_PROXY_NDP_GLOB = "/proc/sys/net/ipv6/conf/*/proxy_ndp"
PROC_STAT_NDISC_CACHE = "/proc/net/stat/ndisc_cache"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0])
    except (ValueError, OSError, IndexError):
        return default


def parse_ndisc_cache(path: str) -> Dict[str, int]:
    totals: Dict[str, int] = {
        "entries": 0,
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
    if not os.path.isfile(path):
        return totals

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
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


def audit_proxy_ndp_guard(
    proxy_glob: str = CONF_PROXY_NDP_GLOB,
    ndisc_stat_path: str = PROC_STAT_NDISC_CACHE,
    warn_unresolved_discards: int = 100,
) -> Dict[str, Any]:
    enabled_interfaces: List[str] = []
    all_enabled_map: Dict[str, int] = {}

    for p in glob.glob(proxy_glob):
        ifname = os.path.basename(os.path.dirname(p))
        val = read_sysctl_int(p, default=-1)
        all_enabled_map[ifname] = val
        if val == 1:
            enabled_interfaces.append(ifname)

    ndisc_stats = parse_ndisc_cache(ndisc_stat_path)
    lookups = ndisc_stats.get("lookups", 0)
    hits = ndisc_stats.get("hits", 0)
    res_failed = ndisc_stats.get("res_failed", 0)
    forced_gc_runs = ndisc_stats.get("forced_gc_runs", 0)
    unresolved_discards = ndisc_stats.get("unresolved_discards", 0)
    table_fulls = ndisc_stats.get("table_fulls", 0)

    hit_ratio_pct = (hits / lookups * 100.0) if lookups > 0 else 100.0

    issues: List[str] = []
    status = "HEALTHY"

    # Loopback must never have Proxy NDP enabled
    if all_enabled_map.get("lo", 0) == 1:
        issues.append(
            "Loopback interface has Proxy NDP enabled (proxy_ndp=1 on lo); "
            "risk of local loopback neighbor resolution interception"
        )
        status = "WARNING"

    # Global or default enablement risk
    if all_enabled_map.get("all", 0) == 1 or all_enabled_map.get("default", 0) == 1:
        issues.append(
            "Global or default Proxy NDP enabled (conf/all or conf/default proxy_ndp=1); "
            "uncontrolled proxy neighbor discovery across newly created interfaces"
        )
        status = "WARNING"

    # External non-lo interfaces enabled
    non_lo_enabled = [i for i in enabled_interfaces if i not in ("lo", "all", "default")]
    if non_lo_enabled:
        issues.append(
            f"Proxy NDP enabled on interfaces: {', '.join(non_lo_enabled)} "
            f"(RFC 4389 proxy advertisement risk)"
        )
        if status != "CRITICAL":
            status = "WARNING"

    # Neighbor table overflow or forced GC
    if table_fulls > 0:
        issues.append(f"NDISC neighbor table overflow detected: {table_fulls} table_full events")
        status = "CRITICAL"
    elif forced_gc_runs > 0:
        issues.append(f"NDISC table forced garbage collection active: {forced_gc_runs} forced GC runs")
        if status != "CRITICAL":
            status = "WARNING"

    # Unresolved discards
    if unresolved_discards >= warn_unresolved_discards:
        issues.append(f"Elevated NDISC unresolved discards: {unresolved_discards:,}")
        if status != "CRITICAL":
            status = "WARNING"

    return {
        "pattern": 259,
        "name": "proxy_ndp",
        "description": "Host IPv6 Proxy Neighbor Discovery (Proxy NDP / RFC 4389) Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "interfaces_audited": len(all_enabled_map),
        "enabled_interfaces_count": len(enabled_interfaces),
        "enabled_interfaces": enabled_interfaces,
        "lo_proxy_ndp": all_enabled_map.get("lo", 0),
        "all_proxy_ndp": all_enabled_map.get("all", 0),
        "default_proxy_ndp": all_enabled_map.get("default", 0),
        "ndisc_lookups": lookups,
        "ndisc_hits": hits,
        "ndisc_hit_ratio_pct": round(hit_ratio_pct, 4),
        "res_failed": res_failed,
        "forced_gc_runs": forced_gc_runs,
        "unresolved_discards": unresolved_discards,
        "table_fulls": table_fulls,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Host IPv6 Proxy Neighbor Discovery (Proxy NDP / RFC 4389) Guard (Pattern 259)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    parser.add_argument("--proxy-glob", default=CONF_PROXY_NDP_GLOB, help="Glob pattern for proxy_ndp sysctls")
    parser.add_argument("--ndisc-file", default=PROC_STAT_NDISC_CACHE, help="Path to /proc/net/stat/ndisc_cache")
    parser.add_argument(
        "--warn-unresolved-discards", type=int, default=100, help="Warning threshold for unresolved discards"
    )

    args = parser.parse_args()

    report = audit_proxy_ndp_guard(
        proxy_glob=args.proxy_glob,
        ndisc_stat_path=args.ndisc_file,
        warn_unresolved_discards=args.warn_unresolved_discards,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Pattern 259: {report['name']} - Status: {report['status']}")
        print(f"  interfaces_audited: {report['interfaces_audited']}")
        print(f"  enabled_interfaces: {report['enabled_interfaces']}")
        print(f"  lo_proxy_ndp: {report['lo_proxy_ndp']}")
        print(f"  ndisc_lookups: {report['ndisc_lookups']}")
        print(f"  ndisc_hits: {report['ndisc_hits']} ({report['ndisc_hit_ratio_pct']}%)")
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
