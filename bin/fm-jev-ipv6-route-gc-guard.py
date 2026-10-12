#!/usr/bin/env python3
"""
bin/fm-jev-ipv6-route-gc-guard.py - Host Network IPv6 Route Garbage Collection & Expiration Policy Guard (Pattern 281 / Pattern 419)

Audits Linux kernel IPv6 routing table garbage collection, route expiration, PMTU cache lifetimes,
and device-down notification policies:
  - /proc/sys/net/ipv6/route/gc_elasticity:
      Multiplier for GC threshold (default 9).
  - /proc/sys/net/ipv6/route/gc_interval:
      Periodic garbage collection sweep interval in seconds (default 30s).
  - /proc/sys/net/ipv6/route/gc_timeout:
      Route cache entry expiration timeout in seconds (default 60s).
  - /proc/sys/net/ipv6/route/gc_min_interval_ms:
      Minimum interval between GC sweeps in milliseconds (default 500ms).
  - /proc/sys/net/ipv6/route/mtu_expires:
      Path MTU exception cache expiration in seconds (default 600s = 10 min).
  - /proc/sys/net/ipv6/route/skip_notify_on_dev_down:
      Suppress route withdrawal notification on dev down (default 0).
  - /proc/net/snmp6:
      IPv6 routing exception telemetry (Ip6InNoRoutes, Ip6OutNoRoutes, Ip6InDiscards, Ip6OutDiscards).

Invariants:
  - skip_notify_on_dev_down must remain 0 to ensure route withdrawal notifications reach userspace daemons.
  - gc_interval must be >= 5s to avoid excessive routing table GC churn.
  - gc_timeout must be >= 10s to avoid premature route entry invalidation.
  - mtu_expires must be >= 60s to preserve stable Path MTU discovery state.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths or snmp6 are missing.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

PROC_IPV6_ROUTE_DIR = "/proc/sys/net/ipv6/route"
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


def parse_snmp6(path: str) -> Dict[str, int]:
    if not os.path.isfile(path):
        return {}
    res: Dict[str, int] = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2:
                    try:
                        res[parts[0]] = int(parts[1])
                    except ValueError:
                        pass
        return res
    except Exception:
        return {}


def audit_ipv6_route_gc_guard(
    route_dir: str = PROC_IPV6_ROUTE_DIR,
    snmp6_file: str = PROC_SNMP6,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    if not os.path.isdir(route_dir):
        return {
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "status": "UNKNOWN",
            "healthy": True,
            "route_dir": route_dir,
            "error": f"IPv6 route sysctl directory not found at {route_dir}",
            "issues": [],
            "recommendations": [],
        }

    gc_elasticity = read_sysctl_int(os.path.join(route_dir, "gc_elasticity"), 9)
    gc_interval = read_sysctl_int(os.path.join(route_dir, "gc_interval"), 30)
    gc_timeout = read_sysctl_int(os.path.join(route_dir, "gc_timeout"), 60)
    gc_min_interval_ms = read_sysctl_int(os.path.join(route_dir, "gc_min_interval_ms"), 500)
    mtu_expires = read_sysctl_int(os.path.join(route_dir, "mtu_expires"), 600)
    skip_notify = read_sysctl_int(os.path.join(route_dir, "skip_notify_on_dev_down"), 0)

    snmp_stats = parse_snmp6(snmp6_file)
    in_receives = snmp_stats.get("Ip6InReceives", 0)
    out_requests = snmp_stats.get("Ip6OutRequests", 0)
    in_no_routes = snmp_stats.get("Ip6InNoRoutes", 0)
    out_no_routes = snmp_stats.get("Ip6OutNoRoutes", 0)
    in_discards = snmp_stats.get("Ip6InDiscards", 0)
    out_discards = snmp_stats.get("Ip6OutDiscards", 0)

    if skip_notify != 0 and skip_notify != -1:
        issues.append(
            f"skip_notify_on_dev_down is enabled ({skip_notify}): "
            "suppresses RTM_DELROUTE netlink notifications to routing daemons on linkdown"
        )
        recommendations.append("Set net.ipv6.route.skip_notify_on_dev_down=0 to ensure daemon route synchronization")
        status = "CRITICAL"

    if gc_interval < 5 and gc_interval != -1:
        issues.append(f"Excessively aggressive IPv6 route gc_interval ({gc_interval}s < 5s)")
        recommendations.append("Restore net.ipv6.route.gc_interval to default 30s")

    if gc_timeout < 10 and gc_timeout != -1:
        issues.append(f"Abnormally short IPv6 route gc_timeout ({gc_timeout}s < 10s)")
        recommendations.append("Restore net.ipv6.route.gc_timeout to default 60s")

    if mtu_expires < 60 and mtu_expires != -1:
        issues.append(f"Abnormally short PMTU exception cache lifetime mtu_expires ({mtu_expires}s < 60s)")
        recommendations.append("Restore net.ipv6.route.mtu_expires to default 600s")

    if gc_elasticity < 1 and gc_elasticity != -1:
        issues.append(f"Invalid gc_elasticity ({gc_elasticity} < 1)")
        recommendations.append("Restore net.ipv6.route.gc_elasticity to default 9")

    if in_receives > 0 and in_no_routes > 0:
        no_route_pct = (in_no_routes / in_receives) * 100.0
        if no_route_pct > 10.0:
            issues.append(f"Elevated IPv6 inbound unroutable drops: {in_no_routes}/{in_receives} ({no_route_pct:.2f}%)")
            recommendations.append("Audit IPv6 default gateway and next-hop reachability")

    if issues and status == "HEALTHY":
        status = "WARNING"

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": (status == "HEALTHY"),
        "gc_elasticity": gc_elasticity,
        "gc_interval_sec": gc_interval,
        "gc_timeout_sec": gc_timeout,
        "gc_min_interval_ms": gc_min_interval_ms,
        "mtu_expires_sec": mtu_expires,
        "skip_notify_on_dev_down": skip_notify,
        "in_receives": in_receives,
        "out_requests": out_requests,
        "in_no_routes": in_no_routes,
        "out_no_routes": out_no_routes,
        "in_discards": in_discards,
        "out_discards": out_discards,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IPv6 Route Garbage Collection & Expiration Policy Guard (Pattern 281 / Pattern 419)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--route-dir", default=PROC_IPV6_ROUTE_DIR, help="Path to IPv6 route sysctl directory")
    parser.add_argument("--snmp6-file", default=PROC_SNMP6, help="Path to /proc/net/snmp6")
    args = parser.parse_args()

    res = audit_ipv6_route_gc_guard(
        route_dir=args.route_dir,
        snmp6_file=args.snmp6_file,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        status_sym = "✓" if res["healthy"] else "✗"
        print(f"[{status_sym}] IPv6 Route GC Guard: {res['status']}")
        print(f"    GC Parameters: interval={res.get('gc_interval_sec', 0)}s | timeout={res.get('gc_timeout_sec', 0)}s | elasticity={res.get('gc_elasticity', 0)} | min_interval={res.get('gc_min_interval_ms', 0)}ms")
        print(f"    Exception Policies: mtu_expires={res.get('mtu_expires_sec', 0)}s | skip_notify_on_dev_down={res.get('skip_notify_on_dev_down', 0)}")
        print(f"    Routing Telemetry: in_receives={res.get('in_receives', 0)} | out_requests={res.get('out_requests', 0)} | in_no_routes={res.get('in_no_routes', 0)} | out_no_routes={res.get('out_no_routes', 0)}")
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
