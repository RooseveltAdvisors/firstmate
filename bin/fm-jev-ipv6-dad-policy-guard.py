#!/usr/bin/env python3
"""
bin/fm-jev-ipv6-dad-policy-guard.py - Linux IPv6 Duplicate Address Detection & Enhanced DAD Policy Guard (Pattern 295 / Pattern 433)

Audits Linux kernel IPv6 Duplicate Address Detection (DAD / RFC 4862) and Enhanced DAD (RFC 7527) loopback
protection settings across all interfaces:
  - /proc/sys/net/ipv6/conf/*/accept_dad: DAD acceptance policy (0=disabled, 1=all, 2=non-EUI64, -1=disabled on lo)
  - /proc/sys/net/ipv6/conf/*/dad_transmits: Consecutive Neighbor Solicitations sent for DAD (default: 1, must be >= 1 on physical links)
  - /proc/sys/net/ipv6/conf/*/enhanced_dad: Enhanced DAD RFC 7527 loopback detection (0=disabled, 1=enabled)
  - /proc/sys/net/ipv6/conf/*/keep_addr_on_down: Retain IPv6 addresses when link loses carrier (0=remove, 1=retain)
  - /proc/net/snmp6: Icmp6InNeighborSolicits, Icmp6OutNeighborSolicits,
                     Icmp6InNeighborAdvertisements, Icmp6OutNeighborAdvertisements,
                     Ip6InAddrErrors

Invariants:
  - accept_dad must be in (-1, 0, 1, 2) across all interfaces (must be >= 1 on active physical links).
  - dad_transmits must be >= 0 across all interfaces (>= 1 recommended for collision detection).
  - enhanced_dad must be 0 or 1 across all interfaces (1 recommended for RFC 7527 reflection defense).
  - keep_addr_on_down must be 0 or 1 across all interfaces.
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


def parse_snmp6_dad(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {
        "Icmp6InNeighborSolicits": 0,
        "Icmp6OutNeighborSolicits": 0,
        "Icmp6InNeighborAdvertisements": 0,
        "Icmp6OutNeighborAdvertisements": 0,
        "Ip6InAddrErrors": 0,
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


def evaluate_ipv6_dad_policy(
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

                accept_dad = read_sysctl_int(os.path.join(iface_dir, "accept_dad"), default=-2)
                dad_transmits = read_sysctl_int(os.path.join(iface_dir, "dad_transmits"), default=-1)
                enhanced_dad = read_sysctl_int(os.path.join(iface_dir, "enhanced_dad"), default=-1)
                keep_addr = read_sysctl_int(os.path.join(iface_dir, "keep_addr_on_down"), default=-1)

                if accept_dad != -2 or dad_transmits != -1:
                    interfaces[entry] = {
                        "accept_dad": accept_dad,
                        "dad_transmits": dad_transmits,
                        "enhanced_dad": enhanced_dad,
                        "keep_addr_on_down": keep_addr,
                    }

                    if accept_dad not in (-2, None) and accept_dad not in (-1, 0, 1, 2):
                        issues.append(
                            f"Interface {entry} accept_dad={accept_dad} invalid (must be -1, 0, 1, or 2)"
                        )
                    if dad_transmits not in (-1, None) and dad_transmits < 0:
                        issues.append(
                            f"Interface {entry} dad_transmits={dad_transmits} invalid (must be >= 0)"
                        )
                    if enhanced_dad not in (-1, None) and enhanced_dad not in (0, 1):
                        issues.append(
                            f"Interface {entry} enhanced_dad={enhanced_dad} invalid (must be 0 or 1)"
                        )
                    if keep_addr not in (-1, None) and keep_addr not in (0, 1):
                        issues.append(
                            f"Interface {entry} keep_addr_on_down={keep_addr} invalid (must be 0 or 1)"
                        )

                    if entry not in ("all", "lo") and accept_dad == 0:
                        issues.append(
                            f"Interface {entry} accept_dad=0 (Duplicate Address Detection disabled on physical link)"
                        )
                        recommendations.append(f"Set net.ipv6.conf.{entry}.accept_dad=1 to prevent address collisions")
        except OSError:
            pass

    snmp6 = parse_snmp6_dad(snmp6_path)

    in_ns = snmp6.get("Icmp6InNeighborSolicits", 0)
    out_ns = snmp6.get("Icmp6OutNeighborSolicits", 0)
    in_na = snmp6.get("Icmp6InNeighborAdvertisements", 0)
    out_na = snmp6.get("Icmp6OutNeighborAdvertisements", 0)
    in_addr_errors = snmp6.get("Ip6InAddrErrors", 0)

    all_accept_dad = interfaces.get("all", {}).get("accept_dad", 0)
    default_accept_dad = interfaces.get("default", {}).get("accept_dad", 1)
    all_dad_transmits = interfaces.get("all", {}).get("dad_transmits", 1)
    default_dad_transmits = interfaces.get("default", {}).get("dad_transmits", 1)
    all_enhanced_dad = interfaces.get("all", {}).get("enhanced_dad", 1)
    default_enhanced_dad = interfaces.get("default", {}).get("enhanced_dad", 1)

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "DEGRADED"

    return {
        "pattern": 295,
        "name": "ipv6_dad_policy",
        "description": "Host Network IPv6 Duplicate Address Detection & Enhanced DAD Policy Guard",
        "status": status,
        "healthy": healthy,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "interfaces_audited": len(interfaces),
        "all_accept_dad": all_accept_dad,
        "default_accept_dad": default_accept_dad,
        "all_dad_transmits": all_dad_transmits,
        "default_dad_transmits": default_dad_transmits,
        "all_enhanced_dad": all_enhanced_dad,
        "default_enhanced_dad": default_enhanced_dad,
        "in_neighbor_solicits": in_ns,
        "out_neighbor_solicits": out_ns,
        "in_neighbor_advertisements": in_na,
        "out_neighbor_advertisements": out_na,
        "in_addr_errors": in_addr_errors,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IPv6 Duplicate Address Detection & Enhanced DAD Policy Guard"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--conf-dir", default=CONF_IPV6_BASE, help="Path to IPv6 conf sysctl directory")
    parser.add_argument("--snmp6-path", default=PROC_SNMP6, help="Path to snmp6 stats file")
    args = parser.parse_args()

    result = evaluate_ipv6_dad_policy(
        conf_dir=args.conf_dir,
        snmp6_path=args.snmp6_path,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] {result['description']}")
        print(f"  Interfaces Audited: {result['interfaces_audited']}")
        print(f"  Accept DAD (all): {result['all_accept_dad']}, Default: {result['default_accept_dad']}")
        print(f"  DAD Transmits (all): {result['all_dad_transmits']}, Default: {result['default_dad_transmits']}")
        print(f"  Enhanced DAD (all): {result['all_enhanced_dad']}, Default: {result['default_enhanced_dad']}")
        print(f"  Inbound NS: {result['in_neighbor_solicits']}, Outbound NS: {result['out_neighbor_solicits']}")
        print(f"  Inbound NA: {result['in_neighbor_advertisements']}, Outbound NA: {result['out_neighbor_advertisements']}")
        print(f"  Inbound Address Errors: {result['in_addr_errors']}")
        if result["issues"]:
            print("  Issues:")
            for issue in result["issues"]:
                print(f"    - {issue}")

    return 0 if result["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
