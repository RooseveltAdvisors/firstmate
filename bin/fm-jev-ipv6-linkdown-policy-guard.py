#!/usr/bin/env python3
"""
bin/fm-jev-ipv6-linkdown-policy-guard.py - Host Network IPv6 Linkdown Route Avoidance & Forwarding Policy Guard (Pattern 280 / Pattern 418)

Audits Linux kernel IPv6 interface linkdown route avoidance, target link-layer address options,
and forwarding override policies across all network interfaces:
  - /proc/sys/net/ipv6/conf/*/ignore_routes_with_linkdown:
      Dead route avoidance on carrier loss (default 0).
  - /proc/sys/net/ipv6/conf/*/force_forwarding:
      Force forwarding on interface even when global forwarding=0 (default 0).
  - /proc/sys/net/ipv6/conf/*/force_tllao:
      Force Target Link-Layer Address Option in NAs (default 0).
  - /proc/sys/net/ipv6/conf/*/accept_ra_from_local:
      Reject local link-local RA reflection loops (default 0).
  - /proc/sys/net/ipv6/conf/*/drop_unicast_in_l2_multicast:
      Drop unicast IPv6 in L2 multicast frames (default 0).
  - /proc/net/snmp6:
      IPv6 routing and forwarding telemetry (Ip6InReceives, Ip6InNoRoutes, Ip6InAddrErrors, Ip6OutForwDatagrams, Ip6OutDiscards).

Invariants:
  - accept_ra_from_local must remain 0 across all interfaces to avoid loopback route hijacking.
  - force_forwarding must remain 0 across all interfaces unless host is a designated router.
  - Excessive Ip6InNoRoutes relative to Ip6InReceives (> 10%) flags routing convergence failure.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths are missing.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Optional

PROC_IPV6_CONF = "/proc/sys/net/ipv6/conf"
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


def audit_ipv6_linkdown_policy_guard(
    conf_dir: str = PROC_IPV6_CONF,
    snmp6_file: str = PROC_SNMP6,
    allow_router_mode: bool = False,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    if not os.path.isdir(conf_dir):
        return {
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "status": "UNKNOWN",
            "healthy": True,
            "conf_dir": conf_dir,
            "error": f"IPv6 conf directory not found at {conf_dir}",
            "issues": [],
            "recommendations": [],
        }

    try:
        interfaces = [
            d for d in os.listdir(conf_dir)
            if os.path.isdir(os.path.join(conf_dir, d)) and not d.startswith(".")
        ]
    except Exception:
        interfaces = []

    if not interfaces:
        interfaces = ["all", "default"]

    iface_policies: Dict[str, Dict[str, int]] = {}
    for iface in sorted(interfaces):
        iface_path = os.path.join(conf_dir, iface)
        iface_policies[iface] = {
            "ignore_routes_with_linkdown": read_sysctl_int(os.path.join(iface_path, "ignore_routes_with_linkdown"), 0),
            "force_forwarding": read_sysctl_int(os.path.join(iface_path, "force_forwarding"), 0),
            "force_tllao": read_sysctl_int(os.path.join(iface_path, "force_tllao"), 0),
            "accept_ra_from_local": read_sysctl_int(os.path.join(iface_path, "accept_ra_from_local"), 0),
            "drop_unicast_in_l2_multicast": read_sysctl_int(os.path.join(iface_path, "drop_unicast_in_l2_multicast"), 0),
        }

    snmp_stats = parse_snmp6(snmp6_file)
    in_receives = snmp_stats.get("Ip6InReceives", 0)
    in_no_routes = snmp_stats.get("Ip6InNoRoutes", 0)
    in_addr_errors = snmp_stats.get("Ip6InAddrErrors", 0)
    out_forw_datagrams = snmp_stats.get("Ip6OutForwDatagrams", 0)
    out_discards = snmp_stats.get("Ip6OutDiscards", 0)

    force_forw_ifaces = [
        iface for iface, pol in iface_policies.items()
        if pol.get("force_forwarding", 0) != 0
    ]
    if force_forw_ifaces and not allow_router_mode:
        issues.append(f"Unexpected force_forwarding enabled on interfaces: {force_forw_ifaces}")
        recommendations.append("Set net.ipv6.conf.<iface>.force_forwarding=0 unless host is a designated router")

    local_ra_ifaces = [
        iface for iface, pol in iface_policies.items()
        if pol.get("accept_ra_from_local", 0) != 0
    ]
    if local_ra_ifaces:
        issues.append(f"accept_ra_from_local enabled on interfaces {local_ra_ifaces}: risks loopback route hijacking")
        recommendations.append("Set net.ipv6.conf.<iface>.accept_ra_from_local=0 to prevent self-reflection loops")
        status = "CRITICAL"

    if in_receives > 0 and in_no_routes > 0:
        no_route_pct = (in_no_routes / in_receives) * 100.0
        if no_route_pct > 10.0:
            issues.append(f"Elevated IPv6 unroutable packet drops: {in_no_routes}/{in_receives} ({no_route_pct:.2f}%)")
            recommendations.append("Audit default gateway reachability and routing daemon convergence")

    if issues and status == "HEALTHY":
        status = "WARNING"

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": (status == "HEALTHY"),
        "interfaces_audited": len(iface_policies),
        "force_forwarding_interfaces": len(force_forw_ifaces),
        "local_ra_interfaces": len(local_ra_ifaces),
        "in_receives": in_receives,
        "in_no_routes": in_no_routes,
        "in_addr_errors": in_addr_errors,
        "out_forw_datagrams": out_forw_datagrams,
        "out_discards": out_discards,
        "interface_policies": iface_policies,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IPv6 Linkdown Route Avoidance & Forwarding Policy Guard (Pattern 280 / Pattern 418)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--conf-dir", default=PROC_IPV6_CONF, help="Path to IPv6 conf sysctl directory")
    parser.add_argument("--snmp6-file", default=PROC_SNMP6, help="Path to /proc/net/snmp6")
    parser.add_argument("--allow-router-mode", action="store_true", help="Allow force_forwarding on interfaces")
    args = parser.parse_args()

    res = audit_ipv6_linkdown_policy_guard(
        conf_dir=args.conf_dir,
        snmp6_file=args.snmp6_file,
        allow_router_mode=args.allow_router_mode,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        status_sym = "✓" if res["healthy"] else "✗"
        print(f"[{status_sym}] IPv6 Linkdown Policy Guard: {res['status']}")
        print(f"    Interfaces Audited: {res.get('interfaces_audited', 0)} | Force Forwarding: {res.get('force_forwarding_interfaces', 0)} | Local RA: {res.get('local_ra_interfaces', 0)}")
        print(f"    SNMP6 Telemetry: InReceives={res.get('in_receives', 0)} | InNoRoutes={res.get('in_no_routes', 0)} | InAddrErrors={res.get('in_addr_errors', 0)}")
        print(f"    Forwarding Telemetry: OutForwDatagrams={res.get('out_forw_datagrams', 0)} | OutDiscards={res.get('out_discards', 0)}")
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
