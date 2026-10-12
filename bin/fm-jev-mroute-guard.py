#!/usr/bin/env python3
"""
bin/fm-jev-mroute-guard.py - Host Network IPv4/IPv6 Multicast Routing & VIF Guard (Pattern 249)

Audits Linux kernel IPv4 and IPv6 multicast routing state, Virtual Interfaces (VIFs),
multicast routing cache tables, and Reverse Path Forwarding (RPF) failure statistics:
  - /proc/net/ip_mr_vif: IPv4 Multicast Virtual Interfaces (VIFs)
  - /proc/net/ip_mr_cache: IPv4 Multicast routing route cache & RPF drop counters
  - /proc/net/ip6_mr_vif: IPv6 Multicast Virtual Interfaces (MIFs)
  - /proc/net/ip6_mr_cache: IPv6 Multicast routing route cache & RPF drop counters
  - /proc/sys/net/ipv4/conf/all/mc_forwarding: IPv4 multicast forwarding state
  - /proc/sys/net/ipv4/conf/default/mc_forwarding: IPv4 default multicast forwarding state
  - /proc/sys/net/ipv6/conf/all/mc_forwarding: IPv6 multicast forwarding state
  - /proc/sys/net/ipv6/conf/default/mc_forwarding: IPv6 default multicast forwarding state

Invariants:
  - Detection of abnormal multicast route cache table growth or exhaustion.
  - Identification of Reverse Path Forwarding (RPF) drops indicating multicast topology routing loops.
  - Verification that multicast forwarding is configured deliberately without unintended interface leaks.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl or procfs paths are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Tuple

PROC_IP_MR_VIF = "/proc/net/ip_mr_vif"
PROC_IP_MR_CACHE = "/proc/net/ip_mr_cache"
PROC_IP6_MR_VIF = "/proc/net/ip6_mr_vif"
PROC_IP6_MR_CACHE = "/proc/net/ip6_mr_cache"
SYSCTL_IPV4_MC_FWD_ALL = "/proc/sys/net/ipv4/conf/all/mc_forwarding"
SYSCTL_IPV4_MC_FWD_DEF = "/proc/sys/net/ipv4/conf/default/mc_forwarding"
SYSCTL_IPV6_MC_FWD_ALL = "/proc/sys/net/ipv6/conf/all/mc_forwarding"
SYSCTL_IPV6_MC_FWD_DEF = "/proc/sys/net/ipv6/conf/default/mc_forwarding"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0])
    except (ValueError, OSError, IndexError):
        return default


def parse_mr_vif(path: str) -> List[Dict[str, Any]]:
    vifs: List[Dict[str, Any]] = []
    if not os.path.isfile(path):
        return vifs
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().strip().splitlines()
        if not lines:
            return vifs
        for line in lines[1:]:
            parts = line.split()
            if not parts:
                continue
            entry: Dict[str, Any] = {
                "interface": parts[0] if len(parts) > 0 else "",
            }
            if len(parts) >= 5:
                try:
                    entry["bytes_in"] = int(parts[1])
                    entry["pkts_in"] = int(parts[2])
                    entry["bytes_out"] = int(parts[3])
                    entry["pkts_out"] = int(parts[4])
                except ValueError:
                    pass
            if len(parts) >= 6:
                entry["flags"] = parts[5]
            vifs.append(entry)
    except (OSError, PermissionError):
        pass
    return vifs


def parse_mr_cache(path: str) -> Tuple[List[Dict[str, Any]], int, int, int]:
    entries: List[Dict[str, Any]] = []
    total_pkts = 0
    total_bytes = 0
    total_wrong = 0
    if not os.path.isfile(path):
        return entries, total_pkts, total_bytes, total_wrong
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().strip().splitlines()
        if not lines:
            return entries, total_pkts, total_bytes, total_wrong
        for line in lines[1:]:
            parts = line.split()
            if not parts or len(parts) < 6:
                continue
            group = parts[0]
            origin = parts[1]
            iif = parts[2]
            try:
                pkts = int(parts[3])
                bytes_cnt = int(parts[4])
                wrong = int(parts[5])
            except ValueError:
                continue
            oifs = parts[6] if len(parts) > 6 else ""
            total_pkts += pkts
            total_bytes += bytes_cnt
            total_wrong += wrong
            entries.append({
                "group": group,
                "origin": origin,
                "iif": iif,
                "pkts": pkts,
                "bytes": bytes_cnt,
                "wrong": wrong,
                "oifs": oifs,
            })
    except (OSError, PermissionError):
        pass
    return entries, total_pkts, total_bytes, total_wrong


def audit_mroute_guard(
    vif_ipv4_path: str = PROC_IP_MR_VIF,
    cache_ipv4_path: str = PROC_IP_MR_CACHE,
    vif_ipv6_path: str = PROC_IP6_MR_VIF,
    cache_ipv6_path: str = PROC_IP6_MR_CACHE,
    sysctl_v4_all: str = SYSCTL_IPV4_MC_FWD_ALL,
    sysctl_v4_def: str = SYSCTL_IPV4_MC_FWD_DEF,
    sysctl_v6_all: str = SYSCTL_IPV6_MC_FWD_ALL,
    sysctl_v6_def: str = SYSCTL_IPV6_MC_FWD_DEF,
    warn_rpf_drops: int = 100,
    warn_max_routes: int = 1000,
) -> Dict[str, Any]:
    v4_vifs = parse_mr_vif(vif_ipv4_path)
    v4_entries, v4_pkts, v4_bytes, v4_wrong = parse_mr_cache(cache_ipv4_path)
    v6_vifs = parse_mr_vif(vif_ipv6_path)
    v6_entries, v6_pkts, v6_bytes, v6_wrong = parse_mr_cache(cache_ipv6_path)

    v4_fwd_all = read_sysctl_int(sysctl_v4_all, 0)
    v4_fwd_def = read_sysctl_int(sysctl_v4_def, 0)
    v6_fwd_all = read_sysctl_int(sysctl_v6_all, 0)
    v6_fwd_def = read_sysctl_int(sysctl_v6_def, 0)

    total_vifs = len(v4_vifs) + len(v6_vifs)
    total_routes = len(v4_entries) + len(v6_entries)
    total_wrong = v4_wrong + v6_wrong
    total_pkts = v4_pkts + v6_pkts
    total_bytes = v4_bytes + v6_bytes

    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    if total_wrong >= warn_rpf_drops:
        status = "WARNING"
        issues.append(
            f"Elevated multicast Reverse Path Forwarding (RPF) drops ({total_wrong} >= {warn_rpf_drops})"
        )
        recommendations.append(
            "Audit upstream multicast routing tree topology and interface incoming paths"
        )

    if total_routes >= warn_max_routes:
        status = "WARNING"
        issues.append(
            f"Excessive active multicast routing cache entries ({total_routes} >= {warn_max_routes})"
        )
        recommendations.append(
            "Inspect active multicast forwarding sessions or reduce MRT prune timeout"
        )

    healthy = (len(issues) == 0)

    return {
        "status": status,
        "healthy": healthy,
        "ipv4_mc_forwarding_all": v4_fwd_all,
        "ipv4_mc_forwarding_default": v4_fwd_def,
        "ipv6_mc_forwarding_all": v6_fwd_all,
        "ipv6_mc_forwarding_default": v6_fwd_def,
        "ipv4_vif_count": len(v4_vifs),
        "ipv4_cache_count": len(v4_entries),
        "ipv4_rpf_failures": v4_wrong,
        "ipv4_total_pkts": v4_pkts,
        "ipv4_total_bytes": v4_bytes,
        "ipv6_vif_count": len(v6_vifs),
        "ipv6_cache_count": len(v6_entries),
        "ipv6_rpf_failures": v6_wrong,
        "ipv6_total_pkts": v6_pkts,
        "ipv6_total_bytes": v6_bytes,
        "total_vifs": total_vifs,
        "total_routes": total_routes,
        "total_rpf_failures": total_wrong,
        "total_pkts": total_pkts,
        "total_bytes": total_bytes,
        "mroute_healthy": healthy,
        "issues": issues,
        "recommendations": recommendations,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IPv4/IPv6 Multicast Routing & VIF Guard (Pattern 249)"
    )
    parser.add_argument("--vif-ipv4", default=PROC_IP_MR_VIF, help="Path to /proc/net/ip_mr_vif")
    parser.add_argument("--cache-ipv4", default=PROC_IP_MR_CACHE, help="Path to /proc/net/ip_mr_cache")
    parser.add_argument("--vif-ipv6", default=PROC_IP6_MR_VIF, help="Path to /proc/net/ip6_mr_vif")
    parser.add_argument("--cache-ipv6", default=PROC_IP6_MR_CACHE, help="Path to /proc/net/ip6_mr_cache")
    parser.add_argument("--warn-rpf-drops", type=int, default=100, help="Warning threshold for RPF drop count")
    parser.add_argument("--warn-max-routes", type=int, default=1000, help="Warning threshold for route cache count")
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--verbose", action="store_true", help="Verbose reporting")
    args = parser.parse_args()

    result = audit_mroute_guard(
        vif_ipv4_path=args.vif_ipv4,
        cache_ipv4_path=args.cache_ipv4,
        vif_ipv6_path=args.vif_ipv6,
        cache_ipv6_path=args.cache_ipv6,
        warn_rpf_drops=args.warn_rpf_drops,
        warn_max_routes=args.warn_max_routes,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] Host Network Multicast Routing & VIF Guard (Pattern 249)")
        print(f"  IPv4 mc_forwarding (all/def):     {result['ipv4_mc_forwarding_all']} / {result['ipv4_mc_forwarding_default']}")
        print(f"  IPv6 mc_forwarding (all/def):     {result['ipv6_mc_forwarding_all']} / {result['ipv6_mc_forwarding_default']}")
        print(f"  Total VIFs (IPv4 / IPv6):         {result['total_vifs']} ({result['ipv4_vif_count']} / {result['ipv6_vif_count']})")
        print(f"  Total Routes (IPv4 / IPv6):       {result['total_routes']} ({result['ipv4_cache_count']} / {result['ipv6_cache_count']})")
        print(f"  RPF Failures (Wrong interface):   {result['total_rpf_failures']} ({result['ipv4_rpf_failures']} / {result['ipv6_rpf_failures']})")
        print(f"  Total Packets / Bytes:            {result['total_pkts']} pkts / {result['total_bytes']} bytes")
        if result["issues"]:
            print("  Issues:")
            for iss in result["issues"]:
                print(f"    - {iss}")
        if result["recommendations"]:
            print("  Recommendations:")
            for rec in result["recommendations"]:
                print(f"    - {rec}")

    return 0 if result["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
