#!/usr/bin/env python3
"""
bin/fm-jev-ipv6-autoconf-guard.py - Linux IPv6 Stateless Address Autoconfiguration (SLAAC / RFC 4862) and RFC 4941 Privacy Extensions Guard (Pattern 286 / Pattern 424)

Audits Linux kernel IPv6 Stateless Address Autoconfiguration (SLAAC / RFC 4862) and RFC 4941
privacy extensions parameters across network interfaces:
  - /proc/sys/net/ipv6/conf/*/autoconf: Whether SLAAC address generation is enabled (default 1).
  - /proc/sys/net/ipv6/conf/*/max_addresses: Maximum number of autoconfigured addresses per interface (default 16).
  - /proc/sys/net/ipv6/conf/*/accept_ra_pinfo: Accept Prefix Information from RA for autoconf (default 1).
  - /proc/sys/net/ipv6/conf/*/use_tempaddr: RFC 4941 privacy extension preference (<=0 off, 1 enabled, 2 prefer temp).
  - /proc/sys/net/ipv6/conf/*/temp_valid_lft: Valid lifetime for temporary privacy addresses in seconds (default 604800s).
  - /proc/sys/net/ipv6/conf/*/temp_prefered_lft: Preferred lifetime for temporary privacy addresses in seconds (default 86400s).
  - /proc/sys/net/ipv6/conf/*/max_desync_factor: Maximum random desync factor for lifetime renewal (default 600s).
  - /proc/sys/net/ipv6/conf/*/regen_max_retry: Maximum retries for temporary address generation upon DAD collision (default 3).
  - /proc/net/snmp6: Ip6InAddrErrors, Ip6InDiscards, Icmp6InRouterAdvertisements, Icmp6InErrors, Icmp6InCsumErrors.

Invariants:
  - temp_prefered_lft must be <= temp_valid_lft (RFC 4941 §3.3 constraint).
  - max_addresses must be >= 1 to permit SLAAC address generation without exhaustion.
  - regen_max_retry must be >= 1 to guarantee collision recovery.
  - Fail-open: graceful fallback when sysctl paths or /proc/net/snmp6 are restricted.
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


def audit_ipv6_autoconf_guard(
    conf_dir: str = CONF_IPV6_BASE,
    snmp6_path: str = PROC_SNMP6,
    max_addresses_floor: int = 1,
) -> Dict[str, Any]:
    interfaces: Dict[str, Dict[str, int]] = {}

    if os.path.isdir(conf_dir):
        for ifname in sorted(os.listdir(conf_dir)):
            iface_path = os.path.join(conf_dir, ifname)
            if os.path.isdir(iface_path):
                interfaces[ifname] = {
                    "autoconf": read_sysctl_int(os.path.join(iface_path, "autoconf"), default=1),
                    "max_addresses": read_sysctl_int(os.path.join(iface_path, "max_addresses"), default=16),
                    "accept_ra_pinfo": read_sysctl_int(os.path.join(iface_path, "accept_ra_pinfo"), default=1),
                    "use_tempaddr": read_sysctl_int(os.path.join(iface_path, "use_tempaddr"), default=0),
                    "temp_valid_lft": read_sysctl_int(os.path.join(iface_path, "temp_valid_lft"), default=604800),
                    "temp_prefered_lft": read_sysctl_int(os.path.join(iface_path, "temp_prefered_lft"), default=86400),
                    "max_desync_factor": read_sysctl_int(os.path.join(iface_path, "max_desync_factor"), default=600),
                    "regen_max_retry": read_sysctl_int(os.path.join(iface_path, "regen_max_retry"), default=3),
                }

    snmp6 = parse_snmp6(snmp6_path)
    in_addr_errors = snmp6.get("Ip6InAddrErrors", 0)
    in_discards = snmp6.get("Ip6InDiscards", 0)
    in_ra = snmp6.get("Icmp6InRouterAdvertisements", 0)
    in_errors = snmp6.get("Icmp6InErrors", 0)
    in_csum_errors = snmp6.get("Icmp6InCsumErrors", 0)

    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    for ifname, params in interfaces.items():
        valid_lft = params["temp_valid_lft"]
        pref_lft = params["temp_prefered_lft"]
        max_addrs = params["max_addresses"]
        regen_retry = params["regen_max_retry"]

        if valid_lft > 0 and pref_lft > valid_lft:
            issues.append(
                f"Interface {ifname}: RFC 4941 preferred lifetime ({pref_lft}s) exceeds "
                f"valid lifetime ({valid_lft}s)"
            )
            status = "CRITICAL"
            recommendations.append(
                f"Ensure /proc/sys/net/ipv6/conf/{ifname}/temp_prefered_lft <= temp_valid_lft"
            )

        if max_addrs >= 0 and max_addrs < max_addresses_floor:
            issues.append(
                f"Interface {ifname}: max_addresses={max_addrs} (< {max_addresses_floor}); "
                "risk of SLAAC address pool exhaustion"
            )
            if status != "CRITICAL":
                status = "WARNING"
            recommendations.append(
                f"Set /proc/sys/net/ipv6/conf/{ifname}/max_addresses to >= 16 (default 16)"
            )

        if regen_retry >= 0 and regen_retry < 1:
            issues.append(
                f"Interface {ifname}: regen_max_retry={regen_retry} (< 1); "
                "risk of unrecoverable DAD collision on privacy addresses"
            )
            if status != "CRITICAL":
                status = "WARNING"
            recommendations.append(
                f"Set /proc/sys/net/ipv6/conf/{ifname}/regen_max_retry to >= 3"
            )

    if in_addr_errors > 100:
        issues.append(f"Elevated IPv6 inbound address errors detected (Ip6InAddrErrors={in_addr_errors})")
        if status != "CRITICAL":
            status = "WARNING"
        recommendations.append("Investigate faulty IPv6 routing or malformed destination addresses")

    if in_csum_errors > 0:
        issues.append(f"ICMPv6 checksum errors detected (Icmp6InCsumErrors={in_csum_errors})")
        if status != "CRITICAL":
            status = "WARNING"
        recommendations.append("Check link layer hardware offloads or packet corruption on interface")

    healthy = (status == "HEALTHY")

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": healthy,
        "interfaces_audited": len(interfaces),
        "all_autoconf": interfaces.get("all", {}).get("autoconf", 1),
        "default_autoconf": interfaces.get("default", {}).get("autoconf", 1),
        "lo_autoconf": interfaces.get("lo", {}).get("autoconf", 1),
        "all_max_addresses": interfaces.get("all", {}).get("max_addresses", 16),
        "default_max_addresses": interfaces.get("default", {}).get("max_addresses", 16),
        "all_accept_ra_pinfo": interfaces.get("all", {}).get("accept_ra_pinfo", 1),
        "default_temp_valid_lft_sec": interfaces.get("default", {}).get("temp_valid_lft", 604800),
        "default_temp_prefered_lft_sec": interfaces.get("default", {}).get("temp_prefered_lft", 86400),
        "default_use_tempaddr": interfaces.get("default", {}).get("use_tempaddr", 2),
        "default_max_desync_factor_sec": interfaces.get("default", {}).get("max_desync_factor", 600),
        "default_regen_max_retry": interfaces.get("default", {}).get("regen_max_retry", 3),
        "in_addr_errors": in_addr_errors,
        "in_discards": in_discards,
        "in_router_advertisements": in_ra,
        "in_errors": in_errors,
        "in_csum_errors": in_csum_errors,
        "slaac_compliant": healthy,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IPv6 Stateless Address Autoconfiguration (SLAAC / RFC 4862) Guard (Pattern 286 / Pattern 424)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--conf-dir", default=CONF_IPV6_BASE, help="Path to IPv6 conf sysctl directory")
    parser.add_argument("--snmp6-file", default=PROC_SNMP6, help="Path to /proc/net/snmp6")
    args = parser.parse_args()

    res = audit_ipv6_autoconf_guard(
        conf_dir=args.conf_dir,
        snmp6_path=args.snmp6_file,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        status_sym = "✓" if res["healthy"] else "✗"
        print(f"[{status_sym}] IPv6 Autoconf Guard: {res['status']}")
        print(f"    SLAAC Policies: autoconf(all)={res.get('all_autoconf', 1)} | max_addresses={res.get('default_max_addresses', 16)} | accept_ra_pinfo={res.get('all_accept_ra_pinfo', 1)}")
        print(f"    Privacy Extensions: use_tempaddr={res.get('default_use_tempaddr', 2)} | valid_lft={res.get('default_temp_valid_lft_sec', 0)}s | pref_lft={res.get('default_temp_prefered_lft_sec', 0)}s | regen_retry={res.get('default_regen_max_retry', 3)}")
        print(f"    Telemetry: in_addr_errors={res.get('in_addr_errors', 0)} | in_discards={res.get('in_discards', 0)} | in_ra={res.get('in_router_advertisements', 0)}")
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
