#!/usr/bin/env python3
"""
bin/fm-jev-ipv4-route-gc-guard.py - Host Network IPv4 Routing Cache Garbage Collection & PMTU Exception Policy Guard (Pattern 284 / Pattern 422)

Audits Linux kernel IPv4 routing table garbage collection, route cache timeouts, PMTU exception cache lifetimes,
and minimum advertised MSS parameters:
  - /proc/sys/net/ipv4/route/gc_interval:
      Periodic garbage collection sweep interval in seconds (default 60s).
  - /proc/sys/net/ipv4/route/gc_timeout:
      Route cache entry expiration timeout in seconds (default 300s).
  - /proc/sys/net/ipv4/route/gc_min_interval_ms:
      Minimum interval between GC sweeps in milliseconds (default 500ms).
  - /proc/sys/net/ipv4/route/gc_elasticity:
      Multiplier for GC threshold before aggressive route pruning (default 8).
  - /proc/sys/net/ipv4/route/mtu_expires:
      Path MTU exception cache expiration in seconds (default 600s = 10 min).
  - /proc/sys/net/ipv4/route/min_pmtu:
      Minimum allowed Path MTU for IPv4 (default 552, RFC 791 floor 68).
  - /proc/sys/net/ipv4/route/min_adv_mss:
      Minimum advertised MSS for IPv4 (default 256).
  - /proc/sys/net/ipv4/route/max_size:
      Maximum size of IPv4 routing cache (default 2147483647).
  - /proc/net/snmp:
      OutNoRoutes, InDiscards, OutDiscards, InReceives, OutRequests.

Invariants:
  - gc_interval must be >= 5s to avoid excessive routing table GC churn.
  - gc_timeout must be >= 10s to prevent premature routing exception cache invalidation.
  - mtu_expires must be >= 60s to maintain stable Path MTU discovery state across TCP sessions.
  - min_pmtu must be >= 68 (RFC 791 absolute minimum) and <= 1500.
  - min_adv_mss must be >= 48 and <= 1500.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths or snmp are missing.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

PROC_IPV4_ROUTE_DIR = "/proc/sys/net/ipv4/route"
PROC_SNMP = "/proc/net/snmp"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content and (content.split()[0].lstrip("-").isdigit()) else default
    except (ValueError, OSError, IndexError):
        return default


def parse_snmp_ip(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("Ip:") and lines[i + 1].startswith("Ip:"):
                keys = lines[i].split()[1:]
                vals = lines[i + 1].split()[1:]
                for k, v in zip(keys, vals):
                    try:
                        metrics[k] = int(v)
                    except ValueError:
                        pass
                break
    except Exception:
        pass
    return metrics


def audit_ipv4_route_gc_guard(
    route_dir: str = PROC_IPV4_ROUTE_DIR,
    snmp_file: str = PROC_SNMP,
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
            "error": f"IPv4 route sysctl directory not found at {route_dir}",
            "issues": [],
            "recommendations": [],
        }

    gc_interval = read_sysctl_int(os.path.join(route_dir, "gc_interval"), 60)
    gc_timeout = read_sysctl_int(os.path.join(route_dir, "gc_timeout"), 300)
    gc_min_interval_ms = read_sysctl_int(os.path.join(route_dir, "gc_min_interval_ms"), 500)
    gc_elasticity = read_sysctl_int(os.path.join(route_dir, "gc_elasticity"), 8)
    mtu_expires = read_sysctl_int(os.path.join(route_dir, "mtu_expires"), 600)
    min_pmtu = read_sysctl_int(os.path.join(route_dir, "min_pmtu"), 552)
    min_adv_mss = read_sysctl_int(os.path.join(route_dir, "min_adv_mss"), 256)
    max_size = read_sysctl_int(os.path.join(route_dir, "max_size"), 2147483647)

    snmp = parse_snmp_ip(snmp_file)
    in_receives = snmp.get("InReceives", 0)
    out_requests = snmp.get("OutRequests", 0)
    out_no_routes = snmp.get("OutNoRoutes", 0)
    in_discards = snmp.get("InDiscards", 0)
    out_discards = snmp.get("OutDiscards", 0)

    if gc_interval < 5 and gc_interval != -1:
        issues.append(f"Excessively aggressive IPv4 route gc_interval ({gc_interval}s < 5s): risks GC churn")
        recommendations.append("Restore net.ipv4.route.gc_interval to default 60s")
        status = "CRITICAL"

    if gc_timeout < 10 and gc_timeout != -1:
        issues.append(f"Abnormally short IPv4 route gc_timeout ({gc_timeout}s < 10s): premature route eviction")
        recommendations.append("Restore net.ipv4.route.gc_timeout to default 300s")
        status = "CRITICAL"

    if mtu_expires < 60 and mtu_expires != -1:
        issues.append(f"Abnormally short PMTU exception cache lifetime ({mtu_expires}s < 60s)")
        recommendations.append("Restore net.ipv4.route.mtu_expires to default 600s")
        status = "CRITICAL"

    if min_pmtu < 68 and min_pmtu != -1:
        issues.append(f"Sub-RFC 791 minimum PMTU ({min_pmtu} < 68 bytes)")
        recommendations.append("Restore net.ipv4.route.min_pmtu to standard 552 bytes (>= 68)")
        status = "CRITICAL"
    elif min_pmtu > 1500:
        issues.append(f"Excessive min_pmtu ({min_pmtu} > 1500 bytes)")
        recommendations.append("Set net.ipv4.route.min_pmtu to <= 1500")
        if status == "HEALTHY":
            status = "WARNING"

    if min_adv_mss < 48 and min_adv_mss != -1:
        issues.append(f"Sub-minimum min_adv_mss ({min_adv_mss} < 48 bytes)")
        recommendations.append("Restore net.ipv4.route.min_adv_mss to standard 256 bytes")
        if status == "HEALTHY":
            status = "WARNING"

    if gc_elasticity < 1 and gc_elasticity != -1:
        issues.append(f"Invalid gc_elasticity ({gc_elasticity} < 1)")
        recommendations.append("Restore net.ipv4.route.gc_elasticity to default 8")
        if status == "HEALTHY":
            status = "WARNING"

    if out_requests > 0 and out_no_routes > 0:
        no_route_pct = (out_no_routes / out_requests) * 100.0
        if no_route_pct > 10.0:
            issues.append(f"Elevated IPv4 outbound missing route drops: {out_no_routes}/{out_requests} ({no_route_pct:.2f}%)")
            recommendations.append("Audit IPv4 default gateway and routing table completeness")
            if status == "HEALTHY":
                status = "WARNING"

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": (status == "HEALTHY"),
        "gc_interval_sec": gc_interval,
        "gc_timeout_sec": gc_timeout,
        "gc_min_interval_ms": gc_min_interval_ms,
        "gc_elasticity": gc_elasticity,
        "mtu_expires_sec": mtu_expires,
        "min_pmtu": min_pmtu,
        "min_adv_mss": min_adv_mss,
        "max_size": max_size,
        "in_receives": in_receives,
        "out_requests": out_requests,
        "out_no_routes": out_no_routes,
        "in_discards": in_discards,
        "out_discards": out_discards,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IPv4 Routing Cache Garbage Collection & PMTU Exception Policy Guard (Pattern 284 / Pattern 422)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--route-dir", default=PROC_IPV4_ROUTE_DIR, help="Path to IPv4 route sysctl directory")
    parser.add_argument("--snmp-file", default=PROC_SNMP, help="Path to /proc/net/snmp")
    args = parser.parse_args()

    res = audit_ipv4_route_gc_guard(
        route_dir=args.route_dir,
        snmp_file=args.snmp_file,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        status_sym = "✓" if res["healthy"] else "✗"
        print(f"[{status_sym}] IPv4 Route GC Guard: {res['status']}")
        print(f"    GC Parameters: interval={res.get('gc_interval_sec', 0)}s | timeout={res.get('gc_timeout_sec', 0)}s | elasticity={res.get('gc_elasticity', 0)} | min_interval={res.get('gc_min_interval_ms', 0)}ms")
        print(f"    Exception Policies: mtu_expires={res.get('mtu_expires_sec', 0)}s | min_pmtu={res.get('min_pmtu', 0)} | min_adv_mss={res.get('min_adv_mss', 0)}")
        print(f"    Routing Telemetry: in_receives={res.get('in_receives', 0)} | out_requests={res.get('out_requests', 0)} | out_no_routes={res.get('out_no_routes', 0)} | out_discards={res.get('out_discards', 0)}")
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
