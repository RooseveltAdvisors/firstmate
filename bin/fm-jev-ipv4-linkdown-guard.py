#!/usr/bin/env python3
"""
bin/fm-jev-ipv4-linkdown-guard.py - Linux IPv4 Linkdown Route Avoidance, Forwarding & Localnet Security Policy Guard (Pattern 298 / Pattern 436)

Audits Linux kernel IPv4 linkdown route avoidance, broadcast forwarding, and localnet routing exposure:
  - /proc/sys/net/ipv4/conf/*/ignore_routes_with_linkdown: Dead route avoidance on carrier loss (default 0)
  - /proc/sys/net/ipv4/conf/*/forwarding: IPv4 interface forwarding mode (default 0 or 1)
  - /proc/sys/net/ipv4/conf/*/mc_forwarding: Multicast routing forwarding (default 0)
  - /proc/sys/net/ipv4/conf/*/bc_forwarding: Directed broadcast forwarding / RFC 2644 Smurf defense (default 0)
  - /proc/sys/net/ipv4/conf/*/accept_local: Accept packets with local source addresses on external interfaces (default 0)
  - /proc/sys/net/ipv4/conf/*/route_localnet: 127.0.0.0/8 loopback routing exposure / RFC 1122 boundary (default 0)
  - /proc/net/snmp: IP InReceives, ForwDatagrams, InAddrErrors, InDiscards, InNoRoutes, OutDiscards, OutNoRoutes

Invariants:
  - bc_forwarding must be 0 across all interfaces to eliminate Smurf amplification.
  - route_localnet must be 0 on non-lo interfaces to prevent external access to loopback services.
  - accept_local must be 0 on external interfaces to prevent local address spoofing.
  - Fail-open: graceful fallback when sysctl paths or /proc/net/snmp are restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

CONF_IPV4_BASE = "/proc/sys/net/ipv4/conf"
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


def parse_snmp_counters(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {
        "InReceives": 0,
        "ForwDatagrams": 0,
        "InAddrErrors": 0,
        "InDiscards": 0,
        "InNoRoutes": 0,
        "OutDiscards": 0,
        "OutNoRoutes": 0,
    }
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("Ip:") and lines[i + 1].startswith("Ip:"):
                headers = lines[i].split()[1:]
                values = lines[i + 1].split()[1:]
                for h, v in zip(headers, values):
                    if h in metrics:
                        try:
                            metrics[h] = int(v)
                        except ValueError:
                            pass
                break
    except Exception:
        pass
    return metrics


def evaluate_ipv4_linkdown(
    conf_dir: str = CONF_IPV4_BASE,
    snmp_path: str = PROC_SNMP,
    allow_mc_forwarding: bool = False,
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

                ld = read_sysctl_int(os.path.join(iface_dir, "ignore_routes_with_linkdown"), default=-1)
                fw = read_sysctl_int(os.path.join(iface_dir, "forwarding"), default=-1)
                mc = read_sysctl_int(os.path.join(iface_dir, "mc_forwarding"), default=-1)
                bc = read_sysctl_int(os.path.join(iface_dir, "bc_forwarding"), default=-1)
                al = read_sysctl_int(os.path.join(iface_dir, "accept_local"), default=-1)
                rl = read_sysctl_int(os.path.join(iface_dir, "route_localnet"), default=-1)

                if ld != -1 or fw != -1 or bc != -1:
                    interfaces[entry] = {
                        "ignore_routes_with_linkdown": ld,
                        "forwarding": fw,
                        "mc_forwarding": mc,
                        "bc_forwarding": bc,
                        "accept_local": al,
                        "route_localnet": rl,
                    }

                    if bc > 0:
                        issues.append(
                            f"Interface {entry}: directed broadcast forwarding enabled (bc_forwarding={bc}, RFC 2644 Smurf amplification risk)"
                        )
                        recommendations.append(
                            f"sysctl -w net.ipv4.conf.{entry}.bc_forwarding=0"
                        )

                    if mc > 0 and not allow_mc_forwarding:
                        issues.append(
                            f"Interface {entry}: multicast routing forwarding enabled on host interface (mc_forwarding={mc})"
                        )
                        recommendations.append(
                            f"sysctl -w net.ipv4.conf.{entry}.mc_forwarding=0"
                        )

                    if entry != "lo" and rl > 0:
                        issues.append(
                            f"Interface {entry}: route_localnet enabled (127.0.0.0/8 loopback network exposed to external routing, RFC 1122 boundary violation)"
                        )
                        recommendations.append(
                            f"sysctl -w net.ipv4.conf.{entry}.route_localnet=0"
                        )

                    if entry != "lo" and al > 0:
                        issues.append(
                            f"Interface {entry}: accept_local enabled on external interface (local address spoofing risk)"
                        )
                        recommendations.append(
                            f"sysctl -w net.ipv4.conf.{entry}.accept_local=0"
                        )
        except OSError:
            pass

    snmp_metrics = parse_snmp_counters(snmp_path)

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    bc_count = sum(1 for p in interfaces.values() if p.get("bc_forwarding", 0) > 0)
    rl_count = sum(1 for iface, p in interfaces.items() if iface != "lo" and p.get("route_localnet", 0) > 0)
    al_count = sum(1 for iface, p in interfaces.items() if iface != "lo" and p.get("accept_local", 0) > 0)

    return {
        "pattern": 298,
        "name": "ipv4_linkdown",
        "status": status,
        "healthy": healthy,
        "interfaces_audited": len(interfaces),
        "all_bc_forwarding": interfaces.get("all", {}).get("bc_forwarding", 0),
        "default_bc_forwarding": interfaces.get("default", {}).get("bc_forwarding", 0),
        "all_route_localnet": interfaces.get("all", {}).get("route_localnet", 0),
        "default_route_localnet": interfaces.get("default", {}).get("route_localnet", 0),
        "all_accept_local": interfaces.get("all", {}).get("accept_local", 0),
        "default_accept_local": interfaces.get("default", {}).get("accept_local", 0),
        "bc_forwarding_enabled_count": bc_count,
        "route_localnet_exposed_count": rl_count,
        "accept_local_exposed_count": al_count,
        "in_receives": snmp_metrics.get("InReceives", 0),
        "forw_datagrams": snmp_metrics.get("ForwDatagrams", 0),
        "in_addr_errors": snmp_metrics.get("InAddrErrors", 0),
        "in_discards": snmp_metrics.get("InDiscards", 0),
        "in_no_routes": snmp_metrics.get("InNoRoutes", 0),
        "out_discards": snmp_metrics.get("OutDiscards", 0),
        "out_no_routes": snmp_metrics.get("OutNoRoutes", 0),
        "interfaces": interfaces,
        "snmp_ip": snmp_metrics,
        "issues": issues,
        "recommendations": recommendations,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network IPv4 Linkdown Route Avoidance, Forwarding & Localnet Security Policy Guard"
    )
    parser.add_argument("--json", action="store_true", help="Output telemetry in JSON format")
    parser.add_argument("--conf-dir", default=CONF_IPV4_BASE, help="Path to IPv4 conf directory")
    parser.add_argument("--snmp-file", default=PROC_SNMP, help="Path to /proc/net/snmp")
    parser.add_argument("--allow-mc-forwarding", action="store_true", help="Allow multicast forwarding")
    args = parser.parse_args()

    result = evaluate_ipv4_linkdown(
        conf_dir=args.conf_dir,
        snmp_path=args.snmp_file,
        allow_mc_forwarding=args.allow_mc_forwarding,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] Jev IPv4 Linkdown Policy Guard")
        print(f"  Interfaces Audited: {result['interfaces_audited']}")
        print(f"  Directed BC Forwarding Enabled: {result['bc_forwarding_enabled_count']}")
        print(f"  Route Localnet Exposed: {result['route_localnet_exposed_count']}")
        print(f"  Accept Local Exposed: {result['accept_local_exposed_count']}")
        print(f"  SNMP InReceives: {result['snmp_ip']['InReceives']:,}")
        print(f"  SNMP ForwDatagrams: {result['snmp_ip']['ForwDatagrams']:,}")
        print(f"  SNMP InAddrErrors: {result['snmp_ip']['InAddrErrors']:,}")
        print(f"  SNMP InDiscards: {result['snmp_ip']['InDiscards']:,}")
        print(f"  SNMP InNoRoutes: {result['snmp_ip']['InNoRoutes']:,}")
        print(f"  SNMP OutDiscards: {result['snmp_ip']['OutDiscards']:,}")
        print(f"  SNMP OutNoRoutes: {result['snmp_ip']['OutNoRoutes']:,}")
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
