#!/usr/bin/env python3
"""
bin/fm-jev-source-route-guard.py - Host Network IPv4/IPv6 Source Routing & RH0 Mitigation Guard (Pattern 248)

Audits Linux kernel IPv4 and IPv6 source routing policies across network interfaces:
  - /proc/sys/net/ipv4/conf/*/accept_source_route (IPv4 source routed packets)
  - /proc/sys/net/ipv6/conf/*/accept_source_route (IPv6 Type 0 Routing Header / RH0)

Invariants:
  - Verification that global IPv4 source routing is disabled (net.ipv4.conf.all.accept_source_route = 0).
  - Verification that global IPv6 Type 0 routing headers are rejected (net.ipv6.conf.all.accept_source_route = 0, RFC 5095).
  - Identification of interfaces permitting source routing when global policy is not enforced.
  - Mitigation of packet spoofing, firewall traversal attacks, and route redirection exploits.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

DEFAULT_IPV4_CONF_DIR = "/proc/sys/net/ipv4/conf"
DEFAULT_IPV6_CONF_DIR = "/proc/sys/net/ipv6/conf"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0])
    except (ValueError, OSError, IndexError):
        return default


def scan_source_route_interfaces(conf_dir: str) -> Dict[str, int]:
    res: Dict[str, int] = {}
    if not os.path.isdir(conf_dir):
        return res
    try:
        for entry in os.listdir(conf_dir):
            iface_dir = os.path.join(conf_dir, entry)
            if os.path.isdir(iface_dir):
                sr_file = os.path.join(iface_dir, "accept_source_route")
                if os.path.isfile(sr_file):
                    res[entry] = read_sysctl_int(sr_file)
    except (OSError, PermissionError):
        pass
    return res


def audit_source_route_guard(
    ipv4_conf_dir: str = DEFAULT_IPV4_CONF_DIR,
    ipv6_conf_dir: str = DEFAULT_IPV6_CONF_DIR,
) -> Dict[str, Any]:
    v4_interfaces = scan_source_route_interfaces(ipv4_conf_dir)
    v6_interfaces = scan_source_route_interfaces(ipv6_conf_dir)

    v4_all = v4_interfaces.get("all", 0)
    v4_default = v4_interfaces.get("default", 0)
    v6_all = v6_interfaces.get("all", 0)
    v6_default = v6_interfaces.get("default", 0)

    issues: List[str] = []
    recommendations: List[str] = []

    # Invariant 1: IPv4 global accept_source_route must be 0
    if v4_all != 0:
        issues.append(
            f"IPv4 source routing is globally permitted (net.ipv4.conf.all.accept_source_route={v4_all}); "
            "allows spoofed packet injection and firewall evasion"
        )
        recommendations.append("Set net.ipv4.conf.all.accept_source_route = 0 via sysctl")

    # Invariant 2: IPv6 global accept_source_route must be 0 (RFC 5095)
    if v6_all != 0:
        issues.append(
            f"IPv6 Type 0 Routing Header (RH0) is globally accepted (net.ipv6.conf.all.accept_source_route={v6_all}); "
            "violates RFC 5095 and enables traffic amplification attacks"
        )
        recommendations.append("Set net.ipv6.conf.all.accept_source_route = 0 via sysctl")

    v4_enabled_ifaces = [iface for iface, val in v4_interfaces.items() if iface not in ("all", "default") and val != 0]
    v6_enabled_ifaces = [iface for iface, val in v6_interfaces.items() if iface not in ("all", "default") and val != 0]

    healthy = (v4_all == 0 and v6_all == 0)
    status = "HEALTHY" if healthy else "CRITICAL"

    return {
        "status": status,
        "healthy": healthy,
        "ipv4_all": v4_all,
        "ipv4_default": v4_default,
        "ipv6_all": v6_all,
        "ipv6_default": v6_default,
        "ipv4_enabled_interfaces_count": len(v4_enabled_ifaces),
        "ipv6_enabled_interfaces_count": len(v6_enabled_ifaces),
        "rfc5095_compliant": (v6_all == 0),
        "source_route_prohibited": (v4_all == 0 and v6_all == 0),
        "ipv4_interfaces": v4_interfaces,
        "ipv6_interfaces": v6_interfaces,
        "v4_enabled_interfaces": v4_enabled_ifaces,
        "v6_enabled_interfaces": v6_enabled_ifaces,
        "issues": issues,
        "recommendations": recommendations,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IPv4/IPv6 Source Routing & RH0 Mitigation Guard (Pattern 248)"
    )
    parser.add_argument("--ipv4-conf-dir", default=DEFAULT_IPV4_CONF_DIR, help="Path to /proc/sys/net/ipv4/conf")
    parser.add_argument("--ipv6-conf-dir", default=DEFAULT_IPV6_CONF_DIR, help="Path to /proc/sys/net/ipv6/conf")
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--verbose", action="store_true", help="Verbose reporting")
    args = parser.parse_args()

    result = audit_source_route_guard(
        ipv4_conf_dir=args.ipv4_conf_dir,
        ipv6_conf_dir=args.ipv6_conf_dir,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] Host Network Source Routing Guard (Pattern 248)")
        print(f"  IPv4 all.accept_source_route:     {result['ipv4_all']}")
        print(f"  IPv4 default.accept_source_route: {result['ipv4_default']}")
        print(f"  IPv6 all.accept_source_route:     {result['ipv6_all']} (RFC 5095 compliant: {result['rfc5095_compliant']})")
        print(f"  IPv6 default.accept_source_route: {result['ipv6_default']}")
        print(f"  Source Routing Prohibited:        {result['source_route_prohibited']}")
        if result["v4_enabled_interfaces"]:
            print(f"  IPv4 Enabled Interfaces:          {', '.join(result['v4_enabled_interfaces'])}")
        if result["v6_enabled_interfaces"]:
            print(f"  IPv6 Enabled Interfaces:          {', '.join(result['v6_enabled_interfaces'])}")
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
