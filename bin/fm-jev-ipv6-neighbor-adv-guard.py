#!/usr/bin/env python3
"""
bin/fm-jev-ipv6-neighbor-adv-guard.py - Linux IPv6 Neighbor Advertisement & Anti-Poisoning Policy Guard (Pattern 290 / Pattern 428)

Audits Linux kernel IPv6 Neighbor Advertisement (RFC 4861, RFC 9131) parameters across all interfaces:
  - /proc/sys/net/ipv6/conf/*/drop_unsolicited_na: Drop unsolicited Neighbor Advertisements (0=accept, 1=drop)
  - /proc/sys/net/ipv6/conf/*/accept_untracked_na: Accept untracked NA to create neighbor entries (0=drop, 1=create INCOMPLETE, 2=create STALE)
  - /proc/net/snmp6: Icmp6InNeighborAdvertisements, Icmp6OutNeighborAdvertisements, Icmp6InNeighborSolicits, Icmp6OutNeighborSolicits
  - /proc/net/stat/ndisc_cache: ND cache lookups, hits, resolution failures, forced GC runs, table full drops

Invariants:
  - drop_unsolicited_na must be 0 or 1 across all interfaces.
  - accept_untracked_na must be 0, 1, or 2 (0 recommended to prevent table poisoning).
  - table_fulls must be 0 to prevent neighbor entry allocation stalls.
  - Fail-open: graceful fallback when sysctl paths or /proc/net are restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

CONF_IPV6_BASE = "/proc/sys/net/ipv6/conf"
PROC_SNMP6 = "/proc/net/snmp6"
PROC_NDISC_CACHE = "/proc/net/stat/ndisc_cache"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content and (content.split()[0].lstrip("-").isdigit()) else default
    except (ValueError, OSError, IndexError):
        return default


def parse_snmp6(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
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


def parse_ndisc_cache(path: str) -> Dict[str, int]:
    totals: Dict[str, int] = {
        "lookups": 0,
        "hits": 0,
        "res_failed": 0,
        "forced_gc_runs": 0,
        "table_fulls": 0,
    }
    if not os.path.isfile(path):
        return totals

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
            if len(lines) < 2:
                return totals

            headers = lines[0].split()
            col_idx: Dict[str, int] = {h: i for i, h in enumerate(headers)}

            for line in lines[1:]:
                parts = line.split()
                if len(parts) != len(headers):
                    continue
                for metric in totals.keys():
                    if metric in col_idx:
                        try:
                            totals[metric] += int(parts[col_idx[metric]], 16)
                        except ValueError:
                            pass
    except Exception:
        pass

    return totals


def audit_ipv6_neighbor_adv_guard(
    conf_dir: str = CONF_IPV6_BASE,
    snmp6_path: str = PROC_SNMP6,
    ndisc_stat_path: str = PROC_NDISC_CACHE,
) -> Dict[str, Any]:
    interfaces: Dict[str, Dict[str, int]] = {}

    if os.path.isdir(conf_dir):
        for entry in sorted(os.listdir(conf_dir)):
            iface_path = os.path.join(conf_dir, entry)
            if os.path.isdir(iface_path):
                interfaces[entry] = {
                    "drop_unsolicited_na": read_sysctl_int(os.path.join(iface_path, "drop_unsolicited_na"), default=0),
                    "accept_untracked_na": read_sysctl_int(os.path.join(iface_path, "accept_untracked_na"), default=0),
                }

    snmp6 = parse_snmp6(snmp6_path)
    in_na = snmp6.get("Icmp6InNeighborAdvertisements", 0)
    out_na = snmp6.get("Icmp6OutNeighborAdvertisements", 0)
    in_ns = snmp6.get("Icmp6InNeighborSolicits", 0)
    out_ns = snmp6.get("Icmp6OutNeighborSolicits", 0)
    in_errors = snmp6.get("Icmp6InErrors", 0)
    in_csum_errors = snmp6.get("Icmp6InCsumErrors", 0)

    nd_stats = parse_ndisc_cache(ndisc_stat_path)
    lookups = nd_stats.get("lookups", 0)
    hits = nd_stats.get("hits", 0)
    res_failed = nd_stats.get("res_failed", 0)
    forced_gc = nd_stats.get("forced_gc_runs", 0)
    table_fulls = nd_stats.get("table_fulls", 0)

    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    for ifname, params in interfaces.items():
        drop_una = params["drop_unsolicited_na"]
        accept_una = params["accept_untracked_na"]

        if drop_una not in (0, 1):
            issues.append(f"Interface {ifname}: invalid drop_unsolicited_na configuration ({drop_una})")
            status = "WARNING"
            recommendations.append(f"Set /proc/sys/net/ipv6/conf/{ifname}/drop_unsolicited_na to 0 or 1.")

        if accept_una not in (0, 1, 2):
            issues.append(f"Interface {ifname}: invalid accept_untracked_na configuration ({accept_una})")
            status = "WARNING"
            recommendations.append(f"Set /proc/sys/net/ipv6/conf/{ifname}/accept_untracked_na to 0, 1, or 2.")
        elif accept_una != 0 and ifname not in ("lo",):
            issues.append(
                f"Interface {ifname}: accept_untracked_na={accept_una} allows untracked NA to allocate "
                "neighbor table entries; risk of neighbor table state exhaustion attacks (RFC 9131)"
            )
            if status != "CRITICAL":
                status = "WARNING"
            recommendations.append(
                f"Set /proc/sys/net/ipv6/conf/{ifname}/accept_untracked_na to 0 on public or shared segments."
            )

    if table_fulls > 0:
        issues.append(f"IPv6 neighbor discovery table full drops detected (table_fulls={table_fulls})")
        status = "CRITICAL"
        recommendations.append("Increase net.ipv6.neigh.default.gc_thresh3 or prune inactive neighbor entries.")

    if forced_gc > 100:
        issues.append(f"Elevated forced neighbor discovery GC runs detected (forced_gc_runs={forced_gc})")
        if status != "CRITICAL":
            status = "WARNING"
        recommendations.append("Check for neighbor cache thrashing or increase gc_thresh2/gc_thresh3.")

    if in_csum_errors > 0:
        issues.append(f"ICMPv6 checksum errors detected (Icmp6InCsumErrors={in_csum_errors})")
        if status != "CRITICAL":
            status = "WARNING"
        recommendations.append("Investigate L2 frame corruption or faulty checksum offload.")

    healthy = (status == "HEALTHY")
    hit_ratio_pct = round((hits / lookups * 100.0), 2) if lookups > 0 else 0.0

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": healthy,
        "interfaces_audited": len(interfaces),
        "all_drop_unsolicited_na": interfaces.get("all", {}).get("drop_unsolicited_na", 0),
        "default_drop_unsolicited_na": interfaces.get("default", {}).get("drop_unsolicited_na", 0),
        "all_accept_untracked_na": interfaces.get("all", {}).get("accept_untracked_na", 0),
        "default_accept_untracked_na": interfaces.get("default", {}).get("accept_untracked_na", 0),
        "in_neighbor_advertisements": in_na,
        "out_neighbor_advertisements": out_na,
        "in_neighbor_solicits": in_ns,
        "out_neighbor_solicits": out_ns,
        "in_errors": in_errors,
        "in_csum_errors": in_csum_errors,
        "ndisc_lookups": lookups,
        "ndisc_hits": hits,
        "ndisc_hit_ratio_pct": hit_ratio_pct,
        "res_failed": res_failed,
        "forced_gc_runs": forced_gc,
        "table_fulls": table_fulls,
        "na_policy_compliant": healthy,
        "issues": issues,
        "recommendations": recommendations,
        "interfaces": interfaces,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IPv6 Neighbor Advertisement & Anti-Poisoning Policy Guard (Pattern 290 / Pattern 428)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--conf-dir", default=CONF_IPV6_BASE, help="Path to IPv6 conf sysctl directory")
    parser.add_argument("--snmp6-file", default=PROC_SNMP6, help="Path to /proc/net/snmp6")
    parser.add_argument("--ndisc-stat-file", default=PROC_NDISC_CACHE, help="Path to /proc/net/stat/ndisc_cache")
    args = parser.parse_args()

    res = audit_ipv6_neighbor_adv_guard(
        conf_dir=args.conf_dir,
        snmp6_path=args.snmp6_file,
        ndisc_stat_path=args.ndisc_stat_file,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        status_sym = "✓" if res["healthy"] else "✗"
        print(f"[{status_sym}] IPv6 Neighbor Advertisement Guard: {res['status']}")
        print(f"    Interfaces: audited={res.get('interfaces_audited', 0)} | all_drop_unsolicited_na={res.get('all_drop_unsolicited_na', 0)} | all_accept_untracked_na={res.get('all_accept_untracked_na', 0)}")
        print(f"    NA/NS Counters: in_na={res.get('in_neighbor_advertisements', 0)} | out_na={res.get('out_neighbor_advertisements', 0)} | out_ns={res.get('out_neighbor_solicits', 0)}")
        print(f"    ND Cache: lookups={res.get('ndisc_lookups', 0)} | hits={res.get('ndisc_hits', 0)} ({res.get('ndisc_hit_ratio_pct', 0)}%) | table_fulls={res.get('table_fulls', 0)}")
        if res["issues"]:
            print("    Issues:")
            for iss in res["issues"]:
                print(f"      - {iss}")
        if res["recommendations"]:
            print("    Recommendations:")
            for rec in res["recommendations"]:
                print(f"      - {rec}")

    return 0 if res["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
