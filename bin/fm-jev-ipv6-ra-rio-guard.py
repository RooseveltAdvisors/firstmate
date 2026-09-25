#!/usr/bin/env python3
"""
bin/fm-jev-ipv6-ra-rio-guard.py - Linux IPv6 Route Information Option (RIO / RFC 4191) & PIO Security Policy Guard (Pattern 291 / Pattern 429)

Audits Linux kernel IPv6 Router Advertisement Route Information Option (RFC 4191) prefix bounds,
router lifetime thresholds (RFC 4861 §6.3.4), and Prefix Information Option (PIO) policies:
  - /proc/sys/net/ipv6/conf/*/accept_ra_rt_info_min_plen: Minimum prefix length of routes accepted from RIO options (default 0)
  - /proc/sys/net/ipv6/conf/*/accept_ra_rt_info_max_plen: Maximum prefix length of routes accepted from RIO options (default 0)
  - /proc/sys/net/ipv6/conf/*/accept_ra_min_lft: Minimum Router Lifetime (seconds) accepted from Router Advertisements (default 0)
  - /proc/sys/net/ipv6/conf/*/ra_honor_pio_life: Enforce honoring PIO valid and preferred lifetimes (default 0)
  - /proc/sys/net/ipv6/conf/*/ra_honor_pio_pflag: Enforce honoring PIO prefix flags (default 0)
  - /proc/net/snmp6: Icmp6InRouterAdvertisements, Icmp6OutRouterAdvertisements,
                     Ip6InNoRoutes, Ip6OutNoRoutes, Ip6InDiscards, Ip6OutDiscards, Icmp6InErrors

Invariants:
  - accept_ra_rt_info_min_plen and accept_ra_rt_info_max_plen must be within [0, 128].
  - If accept_ra_rt_info_max_plen > 0, min_plen must not exceed max_plen.
  - accept_ra_min_lft must be within [0, 65535].
  - ra_honor_pio_life and ra_honor_pio_pflag must be 0 or 1.
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


def evaluate_ra_rio_policy(
    conf_dir: str = CONF_IPV6_BASE,
    snmp6_path: str = PROC_SNMP6,
) -> Dict[str, Any]:
    interfaces: Dict[str, Dict[str, int]] = {}
    issues: List[str] = []

    if os.path.isdir(conf_dir):
        try:
            for entry in sorted(os.listdir(conf_dir)):
                iface_dir = os.path.join(conf_dir, entry)
                if not os.path.isdir(iface_dir):
                    continue

                min_plen = read_sysctl_int(os.path.join(iface_dir, "accept_ra_rt_info_min_plen"), default=-1)
                max_plen = read_sysctl_int(os.path.join(iface_dir, "accept_ra_rt_info_max_plen"), default=-1)
                min_lft = read_sysctl_int(os.path.join(iface_dir, "accept_ra_min_lft"), default=-1)
                pio_life = read_sysctl_int(os.path.join(iface_dir, "ra_honor_pio_life"), default=-1)
                pio_pflag = read_sysctl_int(os.path.join(iface_dir, "ra_honor_pio_pflag"), default=-1)

                if min_plen != -1 or max_plen != -1 or min_lft != -1:
                    interfaces[entry] = {
                        "accept_ra_rt_info_min_plen": min_plen,
                        "accept_ra_rt_info_max_plen": max_plen,
                        "accept_ra_min_lft": min_lft,
                        "ra_honor_pio_life": pio_life,
                        "ra_honor_pio_pflag": pio_pflag,
                    }

                    if min_plen not in (-1, None) and not (0 <= min_plen <= 128):
                        issues.append(
                            f"Interface {entry} accept_ra_rt_info_min_plen={min_plen} out of valid range [0, 128]"
                        )
                    if max_plen not in (-1, None) and not (0 <= max_plen <= 128):
                        issues.append(
                            f"Interface {entry} accept_ra_rt_info_max_plen={max_plen} out of valid range [0, 128]"
                        )
                    if min_plen > 0 and max_plen > 0 and min_plen > max_plen:
                        issues.append(
                            f"Interface {entry} conflicting prefix bounds: min_plen={min_plen} > max_plen={max_plen}"
                        )
                    if min_lft not in (-1, None) and not (0 <= min_lft <= 65535):
                        issues.append(
                            f"Interface {entry} accept_ra_min_lft={min_lft} out of valid range [0, 65535]"
                        )
                    if pio_life not in (-1, None) and pio_life not in (0, 1):
                        issues.append(
                            f"Interface {entry} ra_honor_pio_life={pio_life} invalid (must be 0 or 1)"
                        )
                    if pio_pflag not in (-1, None) and pio_pflag not in (0, 1):
                        issues.append(
                            f"Interface {entry} ra_honor_pio_pflag={pio_pflag} invalid (must be 0 or 1)"
                        )
        except OSError:
            pass

    snmp = parse_snmp6(snmp6_path)
    in_ra = snmp.get("Icmp6InRouterAdvertisements", 0)
    out_ra = snmp.get("Icmp6OutRouterAdvertisements", 0)
    in_no_routes = snmp.get("Ip6InNoRoutes", 0)
    out_no_routes = snmp.get("Ip6OutNoRoutes", 0)
    in_discards = snmp.get("Ip6InDiscards", 0)
    out_discards = snmp.get("Ip6OutDiscards", 0)
    icmp6_in_errors = snmp.get("Icmp6InErrors", 0)

    all_min_plen = interfaces.get("all", {}).get("accept_ra_rt_info_min_plen", 0)
    all_max_plen = interfaces.get("all", {}).get("accept_ra_rt_info_max_plen", 0)
    default_min_plen = interfaces.get("default", {}).get("accept_ra_rt_info_min_plen", 0)
    default_max_plen = interfaces.get("default", {}).get("accept_ra_rt_info_max_plen", 0)
    default_min_lft = interfaces.get("default", {}).get("accept_ra_min_lft", 0)

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "DEGRADED"

    return {
        "pattern": 291,
        "name": "ipv6_ra_rio",
        "description": "Host Network IPv6 Route Information Option (RIO / RFC 4191) & PIO Security Policy Guard",
        "status": status,
        "healthy": healthy,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "interfaces_audited": len(interfaces),
        "all_accept_ra_rt_info_min_plen": all_min_plen,
        "all_accept_ra_rt_info_max_plen": all_max_plen,
        "default_accept_ra_rt_info_min_plen": default_min_plen,
        "default_accept_ra_rt_info_max_plen": default_max_plen,
        "default_accept_ra_min_lft": default_min_lft,
        "in_router_advertisements": in_ra,
        "out_router_advertisements": out_ra,
        "in_no_routes": in_no_routes,
        "out_no_routes": out_no_routes,
        "in_discards": in_discards,
        "out_discards": out_discards,
        "icmp6_in_errors": icmp6_in_errors,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IPv6 Route Information Option (RIO / RFC 4191) & PIO Security Policy Guard"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--conf-dir", default=CONF_IPV6_BASE, help="Path to IPv6 conf sysctl directory")
    parser.add_argument("--snmp6-path", default=PROC_SNMP6, help="Path to snmp6 stats file")
    args = parser.parse_args()

    result = evaluate_ra_rio_policy(
        conf_dir=args.conf_dir,
        snmp6_path=args.snmp6_path,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] {result['description']}")
        print(f"  Interfaces Audited: {result['interfaces_audited']}")
        print(f"  RIO Prefix Bounds (all): min={result['all_accept_ra_rt_info_min_plen']}, max={result['all_accept_ra_rt_info_max_plen']}")
        print(f"  RIO Prefix Bounds (default): min={result['default_accept_ra_rt_info_min_plen']}, max={result['default_accept_ra_rt_info_max_plen']}")
        print(f"  Default Min Router Lifetime: {result['default_accept_ra_min_lft']}s")
        print(f"  Inbound RAs: {result['in_router_advertisements']}, Outbound RAs: {result['out_router_advertisements']}")
        print(f"  Inbound Discards: {result['in_discards']}, ICMPv6 Errors: {result['icmp6_in_errors']}")
        if result["issues"]:
            print("  Issues:")
            for issue in result["issues"]:
                print(f"    - {issue}")

    return 0 if result["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
