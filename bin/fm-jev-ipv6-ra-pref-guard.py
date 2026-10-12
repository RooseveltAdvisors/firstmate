#!/usr/bin/env python3
"""
bin/fm-jev-ipv6-ra-pref-guard.py - Linux IPv6 Router Preference, Default Router & Reachability Probe Guard (Pattern 294 / Pattern 432)

Audits Linux kernel IPv6 Router Advertisement (RA) default router preferences, default route installation,
and router probe reachability interval settings across all interfaces:
  - /proc/sys/net/ipv6/conf/*/accept_ra_rtr_pref: Accept RFC 4191 §2.1 Router Preference (0=ignore, 1=accept)
  - /proc/sys/net/ipv6/conf/*/accept_ra_defrtr: Learn default router from RA (0=disabled, 1=enabled)
  - /proc/sys/net/ipv6/conf/*/router_probe_interval: Minimum interval between router reachability probes (sec, default: 60)
  - /proc/sys/net/ipv6/conf/*/accept_ra_from_local: Accept RA from local addresses (0=disabled, 1=enabled; must be 0)
  - /proc/net/snmp6: Icmp6InRouterAdvertisements, Icmp6OutRouterAdvertisements,
                     Icmp6InRouterSolicits, Icmp6OutRouterSolicits,
                     Ip6InNoRoutes, Ip6OutNoRoutes, Ip6InDiscards, Ip6OutDiscards

Invariants:
  - accept_ra_rtr_pref must be 0 or 1 across all interfaces.
  - accept_ra_defrtr must be 0 or 1 across all interfaces.
  - router_probe_interval must be > 0 across all interfaces (default 60s).
  - accept_ra_from_local must be 0 across all interfaces (prevent loopback route injection).
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


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content and (content.split()[0].lstrip("-").isdigit()) else default
    except (ValueError, OSError, IndexError):
        return default


def parse_snmp6_router(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {
        "Icmp6InRouterAdvertisements": 0,
        "Icmp6OutRouterAdvertisements": 0,
        "Icmp6InRouterSolicits": 0,
        "Icmp6OutRouterSolicits": 0,
        "Ip6InNoRoutes": 0,
        "Ip6OutNoRoutes": 0,
        "Ip6InDiscards": 0,
        "Ip6OutDiscards": 0,
    }
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f.read().splitlines():
                parts = line.strip().split()
                if len(parts) == 2 and parts[0] in metrics:
                    try:
                        metrics[parts[0]] = int(parts[1])
                    except ValueError:
                        metrics[parts[0]] = 0
    except Exception:
        pass
    return metrics


def evaluate_ipv6_ra_pref_policy(
    conf_dir: str = CONF_IPV6_BASE,
    snmp6_path: str = PROC_SNMP6,
) -> Dict[str, Any]:
    interfaces: Dict[str, Dict[str, int]] = {}
    issues: List[str] = []
    recommendations: List[str] = []

    if os.path.isdir(conf_dir):
        try:
            for entry in sorted(os.listdir(conf_dir)):
                iface_dir = os.path.join(conf_dir, entry)
                if not os.path.isdir(iface_dir):
                    continue

                rtr_pref = read_sysctl_int(os.path.join(iface_dir, "accept_ra_rtr_pref"), default=-1)
                defrtr = read_sysctl_int(os.path.join(iface_dir, "accept_ra_defrtr"), default=-1)
                probe_intvl = read_sysctl_int(os.path.join(iface_dir, "router_probe_interval"), default=-1)
                ra_local = read_sysctl_int(os.path.join(iface_dir, "accept_ra_from_local"), default=-1)

                if rtr_pref != -1 or defrtr != -1:
                    interfaces[entry] = {
                        "accept_ra_rtr_pref": rtr_pref,
                        "accept_ra_defrtr": defrtr,
                        "router_probe_interval": probe_intvl,
                        "accept_ra_from_local": ra_local,
                    }

                    if rtr_pref not in (-1, None) and rtr_pref not in (0, 1):
                        issues.append(
                            f"Interface {entry} accept_ra_rtr_pref={rtr_pref} invalid (must be 0 or 1)"
                        )
                    if defrtr not in (-1, None) and defrtr not in (0, 1):
                        issues.append(
                            f"Interface {entry} accept_ra_defrtr={defrtr} invalid (must be 0 or 1)"
                        )
                    if probe_intvl not in (-1, None) and probe_intvl <= 0:
                        issues.append(
                            f"Interface {entry} router_probe_interval={probe_intvl}s invalid (must be > 0)"
                        )
                    if ra_local == 1:
                        issues.append(
                            f"Interface {entry} accept_ra_from_local=1 (loopback RA route injection risk)"
                        )
                        recommendations.append(f"Set net.ipv6.conf.{entry}.accept_ra_from_local=0 to prevent rogue RA injection")
        except OSError:
            pass

    snmp6 = parse_snmp6_router(snmp6_path)

    in_ra = snmp6.get("Icmp6InRouterAdvertisements", 0)
    out_ra = snmp6.get("Icmp6OutRouterAdvertisements", 0)
    in_rs = snmp6.get("Icmp6InRouterSolicits", 0)
    out_rs = snmp6.get("Icmp6OutRouterSolicits", 0)
    in_no_routes = snmp6.get("Ip6InNoRoutes", 0)
    out_no_routes = snmp6.get("Ip6OutNoRoutes", 0)
    in_discards = snmp6.get("Ip6InDiscards", 0)
    out_discards = snmp6.get("Ip6OutDiscards", 0)

    all_rtr_pref = interfaces.get("all", {}).get("accept_ra_rtr_pref", 1)
    default_rtr_pref = interfaces.get("default", {}).get("accept_ra_rtr_pref", 1)
    all_defrtr = interfaces.get("all", {}).get("accept_ra_defrtr", 1)
    default_defrtr = interfaces.get("default", {}).get("accept_ra_defrtr", 1)
    default_probe_intvl = interfaces.get("default", {}).get("router_probe_interval", 60)

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "DEGRADED"

    return {
        "pattern": 294,
        "name": "ipv6_ra_pref",
        "description": "Host Network IPv6 Router Preference, Default Router & Reachability Probe Guard",
        "status": status,
        "healthy": healthy,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "interfaces_audited": len(interfaces),
        "all_accept_ra_rtr_pref": all_rtr_pref,
        "default_accept_ra_rtr_pref": default_rtr_pref,
        "all_accept_ra_defrtr": all_defrtr,
        "default_accept_ra_defrtr": default_defrtr,
        "default_router_probe_interval_sec": default_probe_intvl,
        "in_router_advertisements": in_ra,
        "out_router_advertisements": out_ra,
        "in_router_solicits": in_rs,
        "out_router_solicits": out_rs,
        "in_no_routes": in_no_routes,
        "out_no_routes": out_no_routes,
        "in_discards": in_discards,
        "out_discards": out_discards,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IPv6 Router Preference, Default Router & Reachability Probe Guard"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--conf-dir", default=CONF_IPV6_BASE, help="Path to IPv6 conf sysctl directory")
    parser.add_argument("--snmp6-path", default=PROC_SNMP6, help="Path to snmp6 stats file")
    args = parser.parse_args()

    result = evaluate_ipv6_ra_pref_policy(
        conf_dir=args.conf_dir,
        snmp6_path=args.snmp6_path,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] {result['description']}")
        print(f"  Interfaces Audited: {result['interfaces_audited']}")
        print(f"  Router Preference (all): {result['all_accept_ra_rtr_pref']}, Default: {result['default_accept_ra_rtr_pref']}")
        print(f"  Default Router Learning (all): {result['all_accept_ra_defrtr']}, Default: {result['default_accept_ra_defrtr']}")
        print(f"  Probe Interval (default): {result['default_router_probe_interval_sec']}s")
        print(f"  Inbound RA: {result['in_router_advertisements']}, Outbound RA: {result['out_router_advertisements']}")
        print(f"  Inbound RS: {result['in_router_solicits']}, Outbound RS: {result['out_router_solicits']}")
        print(f"  Inbound No Route: {result['in_no_routes']}, Outbound No Route: {result['out_no_routes']}")
        print(f"  Inbound Discards: {result['in_discards']}, Outbound Discards: {result['out_discards']}")
        if result["issues"]:
            print("  Issues:")
            for issue in result["issues"]:
                print(f"    - {issue}")

    return 0 if result["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
