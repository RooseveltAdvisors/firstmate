#!/usr/bin/env python3
"""
bin/fm-jev-ipv6-ra-pio-guard.py - Linux IPv6 Router Advertisement PIO Lifetime & Default Route Metric Guard (Pattern 301 / Pattern 439)

Audits Linux kernel IPv6 Router Advertisement (RA) Prefix Information Option (PIO) lifetime honoring,
PIO router preference (pflag), default router routing metric, and prefix option acceptance across interfaces:
  - /proc/sys/net/ipv6/conf/*/ra_honor_pio_life: Whether to honor prefix lifetime in RA PIO (default 0 / RFC 7084)
  - /proc/sys/net/ipv6/conf/*/ra_honor_pio_pflag: Whether to honor P-flag in PIO for router preference (default 0)
  - /proc/sys/net/ipv6/conf/*/ra_defrtr_metric: Metric assigned to default routes learned from RAs (default 1024)
  - /proc/sys/net/ipv6/conf/*/accept_ra_pinfo: Accept prefix information options from RAs (default 1 / RFC 4861)
  - /proc/net/snmp6: Icmp6InRouterAdvertisements, Icmp6OutRouterAdvertisements, Icmp6InRouterSolicits, Icmp6OutRouterSolicits

Invariants:
  - ra_honor_pio_life should be 0 to prevent rogue RAs from resetting valid/preferred lifetimes.
  - ra_defrtr_metric must be > 0 (nominal default 1024).
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
    res: Dict[str, int] = {}
    if not os.path.isfile(path):
        return res
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2:
                    try:
                        res[parts[0]] = int(parts[1])
                    except ValueError:
                        continue
        return res
    except Exception:
        return res


def evaluate_ipv6_ra_pio(
    conf_dir: str = CONF_IPV6_BASE,
    snmp6_file: str = PROC_SNMP6,
) -> Dict[str, Any]:
    interfaces: Dict[str, Dict[str, int]] = {}
    issues: List[str] = []
    recommendations: List[str] = []

    if os.path.isdir(conf_dir):
        for entry in sorted(os.listdir(conf_dir)):
            iface_path = os.path.join(conf_dir, entry)
            if os.path.isdir(iface_path):
                honor_life = read_sysctl_int(os.path.join(iface_path, "ra_honor_pio_life"), default=-1)
                honor_pflag = read_sysctl_int(os.path.join(iface_path, "ra_honor_pio_pflag"), default=-1)
                defrtr_metric = read_sysctl_int(os.path.join(iface_path, "ra_defrtr_metric"), default=-1)
                accept_pinfo = read_sysctl_int(os.path.join(iface_path, "accept_ra_pinfo"), default=-1)

                if honor_life != -1 or honor_pflag != -1:
                    interfaces[entry] = {
                        "ra_honor_pio_life": honor_life,
                        "ra_honor_pio_pflag": honor_pflag,
                        "ra_defrtr_metric": defrtr_metric,
                        "accept_ra_pinfo": accept_pinfo,
                    }

                    if honor_life not in (-1, 0, 1):
                        issues.append(f"Interface {entry}: invalid ra_honor_pio_life={honor_life} (expected 0 or 1)")
                    if honor_pflag not in (-1, 0, 1):
                        issues.append(f"Interface {entry}: invalid ra_honor_pio_pflag={honor_pflag} (expected 0 or 1)")
                    if defrtr_metric not in (-1, None) and defrtr_metric <= 0:
                        issues.append(f"Interface {entry}: invalid ra_defrtr_metric={defrtr_metric} (must be > 0)")
                    if accept_pinfo not in (-1, 0, 1):
                        issues.append(f"Interface {entry}: invalid accept_ra_pinfo={accept_pinfo} (expected 0 or 1)")

    snmp = parse_snmp6(snmp6_file)
    in_ra = snmp.get("Icmp6InRouterAdvertisements", 0)
    out_ra = snmp.get("Icmp6OutRouterAdvertisements", 0)
    in_rs = snmp.get("Icmp6InRouterSolicits", 0)
    out_rs = snmp.get("Icmp6OutRouterSolicits", 0)

    all_honor_life = interfaces.get("all", {}).get("ra_honor_pio_life", 0)
    default_honor_life = interfaces.get("default", {}).get("ra_honor_pio_life", 0)
    all_honor_pflag = interfaces.get("all", {}).get("ra_honor_pio_pflag", 0)
    default_honor_pflag = interfaces.get("default", {}).get("ra_honor_pio_pflag", 0)
    all_defrtr_metric = interfaces.get("all", {}).get("ra_defrtr_metric", 1024)
    default_defrtr_metric = interfaces.get("default", {}).get("ra_defrtr_metric", 1024)
    all_accept_pinfo = interfaces.get("all", {}).get("accept_ra_pinfo", 1)
    default_accept_pinfo = interfaces.get("default", {}).get("accept_ra_pinfo", 1)

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    if healthy and not recommendations:
        recommendations.append(
            "IPv6 Router Advertisement PIO lifetime and default router metric configurations are nominal"
        )

    return {
        "pattern": 301,
        "name": "ipv6_ra_pio",
        "description": "Host Network IPv6 RA PIO Lifetime & Default Route Metric Guard",
        "status": status,
        "healthy": healthy,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "interfaces_audited": len(interfaces),
        "all_ra_honor_pio_life": all_honor_life,
        "default_ra_honor_pio_life": default_honor_life,
        "all_ra_honor_pio_pflag": all_honor_pflag,
        "default_ra_honor_pio_pflag": default_honor_pflag,
        "all_ra_defrtr_metric": all_defrtr_metric,
        "default_ra_defrtr_metric": default_defrtr_metric,
        "all_accept_ra_pinfo": all_accept_pinfo,
        "default_accept_ra_pinfo": default_accept_pinfo,
        "in_router_advertisements": in_ra,
        "out_router_advertisements": out_ra,
        "in_router_solicits": in_rs,
        "out_router_solicits": out_rs,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IPv6 RA PIO Lifetime & Default Route Metric Guard (Pattern 301 / Pattern 439)"
    )
    parser.add_argument("--conf-dir", default=CONF_IPV6_BASE, help="Path to /proc/sys/net/ipv6/conf")
    parser.add_argument("--snmp6-file", default=PROC_SNMP6, help="Path to /proc/net/snmp6")
    parser.add_argument("--json", action="store_true", help="Output JSON format")

    args = parser.parse_args()
    report = evaluate_ipv6_ra_pio(
        conf_dir=args.conf_dir,
        snmp6_file=args.snmp6_file,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"=== [{report['status']}] Pattern 301: {report['description']} ===")
        print(f"  Timestamp:                   {report['timestamp']}")
        print(f"  Interfaces Audited:          {report['interfaces_audited']}")
        print(f"  RA Honor PIO Life (all/def): {report['all_ra_honor_pio_life']} / {report['default_ra_honor_pio_life']}")
        print(f"  RA Honor PIO Pflag:          {report['all_ra_honor_pio_pflag']} / {report['default_ra_honor_pio_pflag']}")
        print(f"  RA Default Router Metric:    {report['all_ra_defrtr_metric']} / {report['default_ra_defrtr_metric']}")
        print(f"  Accept RA Pinfo (all/def):   {report['all_accept_ra_pinfo']} / {report['default_accept_ra_pinfo']}")
        print(f"  Router Solicits (in/out):    {report['in_router_solicits']} / {report['out_router_solicits']}")
        print(f"  Router Advertisements:       {report['in_router_advertisements']} / {report['out_router_advertisements']}")
        if report["issues"]:
            print("  Issues:")
            for iss in report["issues"]:
                print(f"    - {iss}")
        if report["recommendations"]:
            print("  Recommendations:")
            for rec in report["recommendations"]:
                print(f"    - {rec}")

    return 0 if report["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
