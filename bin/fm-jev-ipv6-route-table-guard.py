#!/usr/bin/env python3
"""
bin/fm-jev-ipv6-route-table-guard.py - Linux IPv6 Route Table Capacity, GC Threshold & MSS Policy Guard (Pattern 287 / Pattern 425)

Audits Linux kernel IPv6 routing table capacity, synchronous garbage collection thresholds,
minimum advertised MSS, and active route entry saturation:
  - /proc/sys/net/ipv6/route/max_size: Maximum route capacity in IPv6 FIB table (default 2147483647 or 4096).
  - /proc/sys/net/ipv6/route/gc_thresh: Threshold for synchronous GC runs (default 1024).
  - /proc/sys/net/ipv6/route/min_adv_mss: Minimum advertised MSS for IPv6 routes (default 1220 per RFC 8200).
  - /proc/net/ipv6_route: Active IPv6 route table entries.
  - /proc/net/snmp6: Routing drop and failure telemetry (Ip6InNoRoutes, Ip6OutNoRoutes, Ip6InDiscards, Ip6OutDiscards).

Invariants:
  - min_adv_mss must be >= 1220 (RFC 8200 minimum MTU 1280 - 60 bytes IPv6+TCP headers) and <= 65535.
  - gc_thresh must be >= 128 to prevent thrashing synchronous GC runs.
  - max_size must be >= gc_thresh to ensure GC operates before routing table exhaustion.
  - Fail-open: graceful fallback when sysctl paths or /proc/net/ipv6_route are restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

PROC_IPV6_ROUTE_DIR = "/proc/sys/net/ipv6/route"
PROC_IPV6_ROUTE_FILE = "/proc/net/ipv6_route"
PROC_SNMP6 = "/proc/net/snmp6"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content and (content.split()[0].lstrip("-").isdigit()) else default
    except (ValueError, OSError, IndexError):
        return default


def count_routes(path: str) -> int:
    if not os.path.isfile(path):
        return 0
    try:
        count = 0
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for _ in f:
                count += 1
        return count
    except Exception:
        return 0


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


def audit_ipv6_route_table_guard(
    route_dir: str = PROC_IPV6_ROUTE_DIR,
    route_file: str = PROC_IPV6_ROUTE_FILE,
    snmp6_path: str = PROC_SNMP6,
    min_mss_floor: int = 1220,
) -> Dict[str, Any]:
    max_size = read_sysctl_int(os.path.join(route_dir, "max_size"), default=2147483647)
    gc_thresh = read_sysctl_int(os.path.join(route_dir, "gc_thresh"), default=1024)
    min_adv_mss = read_sysctl_int(os.path.join(route_dir, "min_adv_mss"), default=1220)

    active_routes = count_routes(route_file)
    snmp6 = parse_snmp6(snmp6_path)
    in_no_routes = snmp6.get("Ip6InNoRoutes", 0)
    out_no_routes = snmp6.get("Ip6OutNoRoutes", 0)
    in_discards = snmp6.get("Ip6InDiscards", 0)
    out_discards = snmp6.get("Ip6OutDiscards", 0)

    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    if min_adv_mss < min_mss_floor:
        issues.append(
            f"Suboptimal IPv6 min_adv_mss ({min_adv_mss} < {min_mss_floor}); "
            "violates RFC 8200 minimum MTU derivation (1280 - 60 = 1220)"
        )
        status = "WARNING"
        recommendations.append(f"Set /proc/sys/net/ipv6/route/min_adv_mss to >= {min_mss_floor}")

    if gc_thresh < 128:
        issues.append(
            f"Low IPv6 routing gc_thresh ({gc_thresh} < 128); risks excessive synchronous GC sweeps"
        )
        if status != "CRITICAL":
            status = "WARNING"
        recommendations.append("Increase /proc/sys/net/ipv6/route/gc_thresh to >= 1024")

    if max_size < gc_thresh and max_size > 0:
        issues.append(
            f"Inconsistent IPv6 routing table limits: max_size ({max_size}) is smaller than "
            f"gc_thresh ({gc_thresh})"
        )
        status = "CRITICAL"
        recommendations.append("Ensure /proc/sys/net/ipv6/route/max_size >= gc_thresh")

    if gc_thresh > 0 and active_routes >= gc_thresh:
        issues.append(
            f"IPv6 routing table saturated against GC threshold: {active_routes}/{gc_thresh} entries "
            f"({(active_routes / gc_thresh) * 100:.1f}%)"
        )
        if status != "CRITICAL":
            status = "WARNING"
        recommendations.append("Increase /proc/sys/net/ipv6/route/gc_thresh or prune inactive routes")

    if max_size > 0 and active_routes >= max_size:
        issues.append(
            f"IPv6 routing table fully exhausted: {active_routes}/{max_size} entries; route insertion blocked"
        )
        status = "CRITICAL"
        recommendations.append("Increase /proc/sys/net/ipv6/route/max_size immediately")

    healthy = (status == "HEALTHY")
    gc_saturation_pct = round((active_routes / gc_thresh * 100.0), 2) if gc_thresh > 0 else 0.0

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": healthy,
        "max_size": max_size,
        "gc_thresh": gc_thresh,
        "min_adv_mss": min_adv_mss,
        "active_routes": active_routes,
        "gc_saturation_pct": gc_saturation_pct,
        "in_no_routes": in_no_routes,
        "out_no_routes": out_no_routes,
        "in_discards": in_discards,
        "out_discards": out_discards,
        "table_healthy": healthy,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IPv6 Route Table Capacity, GC Threshold & MSS Policy Guard (Pattern 287 / Pattern 425)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--route-dir", default=PROC_IPV6_ROUTE_DIR, help="Path to IPv6 route sysctl directory")
    parser.add_argument("--route-file", default=PROC_IPV6_ROUTE_FILE, help="Path to /proc/net/ipv6_route")
    parser.add_argument("--snmp6-file", default=PROC_SNMP6, help="Path to /proc/net/snmp6")
    args = parser.parse_args()

    res = audit_ipv6_route_table_guard(
        route_dir=args.route_dir,
        route_file=args.route_file,
        snmp6_path=args.snmp6_file,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        status_sym = "✓" if res["healthy"] else "✗"
        print(f"[{status_sym}] IPv6 Route Table Guard: {res['status']}")
        print(f"    Capacity & GC: max_size={res.get('max_size', 0)} | gc_thresh={res.get('gc_thresh', 0)} | min_adv_mss={res.get('min_adv_mss', 0)}")
        print(f"    Route Entries: active_routes={res.get('active_routes', 0)} | gc_saturation={res.get('gc_saturation_pct', 0)}%")
        print(f"    SNMP6 Route Drops: in_no_routes={res.get('in_no_routes', 0)} | out_no_routes={res.get('out_no_routes', 0)} | in_discards={res.get('in_discards', 0)}")
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
