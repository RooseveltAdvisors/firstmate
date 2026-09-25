#!/usr/bin/env python3
"""
bin/fm-jev-fib-multipath-guard.py - Linux FIB ECMP Multipath & Nexthop Routing Guard (Pattern 303 / Pattern 441)

Audits Linux kernel IPv4 and IPv6 Forwarding Information Base (FIB) Equal-Cost Multi-Path (ECMP) routing configuration:
  - /proc/sys/net/ipv4/fib_multipath_hash_policy: IPv4 multipath hashing policy (0=L3, 1=L4, 2=L3/L4 inner, 3=custom)
  - /proc/sys/net/ipv4/fib_multipath_hash_fields: IPv4 custom multipath hash fields bitmap (default 7)
  - /proc/sys/net/ipv4/fib_multipath_hash_seed: IPv4 multipath hash seed (0=kernel random seed)
  - /proc/sys/net/ipv4/fib_multipath_use_neigh: Check neighbor state before selecting multipath nexthop
  - /proc/sys/net/ipv4/fib_sync_mem: Allocated sync memory for FIB operations in bytes
  - /proc/sys/net/ipv6/fib_multipath_hash_policy: IPv6 multipath hashing policy
  - /proc/sys/net/ipv6/fib_multipath_hash_fields: IPv6 custom multipath hash fields bitmap
  - /proc/net/route: Active IPv4 kernel routing table entries count

Invariants:
  - Hash policy must be valid (0=L3_SIP_DIP, 1=L4_5TUPLE, 2=L3_L4_INNER, 3=CUSTOM_FIELDS).
  - fib_sync_mem must be >= min_sync_mem_bytes (default 65536).
  - Route table must contain at least 1 routing entry.
  - Fail-open: graceful fallback when sysctl paths are restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

SYSCTL_IPV4_HASH_POLICY = "/proc/sys/net/ipv4/fib_multipath_hash_policy"
SYSCTL_IPV4_HASH_FIELDS = "/proc/sys/net/ipv4/fib_multipath_hash_fields"
SYSCTL_IPV4_HASH_SEED = "/proc/sys/net/ipv4/fib_multipath_hash_seed"
SYSCTL_IPV4_USE_NEIGH = "/proc/sys/net/ipv4/fib_multipath_use_neigh"
SYSCTL_IPV4_SYNC_MEM = "/proc/sys/net/ipv4/fib_sync_mem"
SYSCTL_IPV6_HASH_POLICY = "/proc/sys/net/ipv6/fib_multipath_hash_policy"
SYSCTL_IPV6_HASH_FIELDS = "/proc/sys/net/ipv6/fib_multipath_hash_fields"
PROC_ROUTE = "/proc/net/route"

POLICY_NAMES: Dict[int, str] = {
    0: "L3_SIP_DIP",
    1: "L4_5TUPLE",
    2: "L3_L4_INNER",
    3: "CUSTOM_FIELDS",
}


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content and (content.split()[0].lstrip("-").isdigit()) else default
    except (ValueError, OSError, IndexError):
        return default


def parse_route_entries(path: str) -> int:
    if not os.path.isfile(path):
        return 0
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        return max(0, len(lines) - 1)
    except OSError:
        return 0


def evaluate_fib_multipath(
    ipv4_hash_policy_file: str = SYSCTL_IPV4_HASH_POLICY,
    ipv4_hash_fields_file: str = SYSCTL_IPV4_HASH_FIELDS,
    ipv4_hash_seed_file: str = SYSCTL_IPV4_HASH_SEED,
    ipv4_use_neigh_file: str = SYSCTL_IPV4_USE_NEIGH,
    ipv4_sync_mem_file: str = SYSCTL_IPV4_SYNC_MEM,
    ipv6_hash_policy_file: str = SYSCTL_IPV6_HASH_POLICY,
    ipv6_hash_fields_file: str = SYSCTL_IPV6_HASH_FIELDS,
    route_file: str = PROC_ROUTE,
    warn_on_l3_only: bool = False,
    warn_on_no_neigh: bool = False,
    min_sync_mem_bytes: int = 65536,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    v4_policy = read_sysctl_int(ipv4_hash_policy_file)
    v4_fields = read_sysctl_int(ipv4_hash_fields_file)
    v4_seed = read_sysctl_int(ipv4_hash_seed_file)
    v4_use_neigh = read_sysctl_int(ipv4_use_neigh_file)
    v4_sync_mem = read_sysctl_int(ipv4_sync_mem_file)
    v6_policy = read_sysctl_int(ipv6_hash_policy_file)
    v6_fields = read_sysctl_int(ipv6_hash_fields_file)
    route_count = parse_route_entries(route_file)

    v4_policy_name = POLICY_NAMES.get(v4_policy, "UNKNOWN")
    v6_policy_name = POLICY_NAMES.get(v6_policy, "UNKNOWN")

    if v4_policy == 0 and warn_on_l3_only:
        issues.append(
            "IPv4 FIB multipath hashing is limited to Layer 3 (SIP/DIP); multi-stream traffic between single IP pairs will not balance across ECMP paths"
        )
        recommendations.append("Set sysctl net.ipv4.fib_multipath_hash_policy=1 for L4 5-tuple multipath hashing")
        status = "WARNING"

    if v4_use_neigh == 0 and warn_on_no_neigh:
        issues.append(
            "IPv4 FIB multipath neighbor reachability check is disabled (fib_multipath_use_neigh=0); traffic may route to dead nexthops"
        )
        recommendations.append("Set sysctl net.ipv4.fib_multipath_use_neigh=1 to verify neighbor state before nexthop selection")
        if status != "CRITICAL":
            status = "WARNING"

    if 0 <= v4_sync_mem < min_sync_mem_bytes:
        issues.append(
            f"IPv4 FIB sync memory ({v4_sync_mem} B) is below minimum threshold ({min_sync_mem_bytes} B)"
        )
        recommendations.append(f"Increase sysctl net.ipv4.fib_sync_mem to at least {min_sync_mem_bytes} bytes")
        if status != "CRITICAL":
            status = "WARNING"

    if v4_policy not in (0, 1, 2, 3, -1):
        issues.append(f"Unrecognized IPv4 FIB multipath hash policy value: {v4_policy}")
        status = "CRITICAL"

    if v6_policy not in (0, 1, 2, 3, -1):
        issues.append(f"Unrecognized IPv6 FIB multipath hash policy value: {v6_policy}")
        status = "CRITICAL"

    healthy = len(issues) == 0

    return {
        "pattern": 303,
        "name": "fib_multipath",
        "description": "Linux FIB ECMP Multipath & Nexthop Routing Guard",
        "status": status,
        "healthy": healthy,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "ipv4_hash_policy": v4_policy,
        "ipv4_hash_policy_name": v4_policy_name,
        "ipv4_hash_fields": v4_fields,
        "ipv4_hash_seed": v4_seed,
        "ipv4_use_neigh": v4_use_neigh,
        "ipv4_sync_mem_bytes": v4_sync_mem,
        "ipv6_hash_policy": v6_policy,
        "ipv6_hash_policy_name": v6_policy_name,
        "ipv6_hash_fields": v6_fields,
        "route_count": route_count,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Linux FIB ECMP Multipath & Nexthop Routing Guard (Pattern 303 / Pattern 441)"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--warn-on-l3-only", action="store_true", help="Warn if hash policy is limited to L3 (SIP/DIP)")
    parser.add_argument("--warn-on-no-neigh", action="store_true", help="Warn if neighbor reachability check is disabled")
    args = parser.parse_args()

    result = evaluate_fib_multipath(
        warn_on_l3_only=args.warn_on_l3_only,
        warn_on_no_neigh=args.warn_on_no_neigh,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] Pattern {result['pattern']} - {result['description']}")
        print(f"  IPv4 Hash Policy: {result['ipv4_hash_policy']} ({result['ipv4_hash_policy_name']})")
        print(f"  IPv4 Hash Fields: {result['ipv4_hash_fields']}, Seed: {result['ipv4_hash_seed']}")
        print(f"  IPv4 Use Neigh: {result['ipv4_use_neigh']}, Sync Mem: {result['ipv4_sync_mem_bytes']} B")
        print(f"  IPv6 Hash Policy: {result['ipv6_hash_policy']} ({result['ipv6_hash_policy_name']}), Fields: {result['ipv6_hash_fields']}")
        print(f"  Active Route Entries: {result['route_count']}")
        if result["issues"]:
            print("  Issues:")
            for issue in result["issues"]:
                print(f"    - {issue}")
        if result["recommendations"]:
            print("  Recommendations:")
            for rec in result["recommendations"]:
                print(f"    - {rec}")

    if not result["healthy"]:
        sys.exit(1 if result["status"] == "WARNING" else 2)


if __name__ == "__main__":
    main()
