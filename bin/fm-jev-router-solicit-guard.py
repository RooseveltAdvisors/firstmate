#!/usr/bin/env python3
"""
bin/fm-jev-router-solicit-guard.py - Host IPv6 Router Solicitation (RS / RFC 4861 / RFC 7559) & ICMPv6 Discovery Guard (Pattern 260)

Audits Linux kernel RFC 4861 / RFC 7559 IPv6 Router Solicitation parameters and SNMP ICMPv6 telemetry:
  - conf/*/router_solicitations: Number of RS transmissions before assuming no routers (-1 or positive integer).
  - conf/*/router_solicitation_interval: Interval between RS transmissions in seconds (default 4s).
  - conf/*/router_solicitation_delay: Initial delay before first RS in seconds (default 1s).
  - conf/*/router_solicitation_max_interval: RFC 7559 exponential backoff ceiling (default 3600s).
  - snmp6 telemetry: Icmp6InRouterSolicits, Icmp6OutRouterSolicits, Icmp6InRouterAdvertisements, Icmp6OutRouterAdvertisements.

Invariants:
  - Prevents Router Solicitation flood storms, synchronization bursts, and loopback RS leaks.
  - Ensures RFC 4861 / RFC 7559 compliance across multi-agent cluster and container host networks.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths or snmp6 are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import glob
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
        return int(content.split()[0])
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
    except OSError:
        pass
    return metrics


def audit_router_solicit_guard(
    conf_dir: str = CONF_IPV6_BASE,
    snmp6_path: str = PROC_SNMP6,
    warn_rs_interval_floor: int = 1,
) -> Dict[str, Any]:
    all_solicitations: Dict[str, int] = {}
    all_intervals: Dict[str, int] = {}
    all_delays: Dict[str, int] = {}
    all_max_intervals: Dict[str, int] = {}

    if os.path.isdir(conf_dir):
        for entry in os.listdir(conf_dir):
            iface_path = os.path.join(conf_dir, entry)
            if os.path.isdir(iface_path):
                ifname = entry
                sol_p = os.path.join(iface_path, "router_solicitations")
                int_p = os.path.join(iface_path, "router_solicitation_interval")
                del_p = os.path.join(iface_path, "router_solicitation_delay")
                max_p = os.path.join(iface_path, "router_solicitation_max_interval")

                if os.path.isfile(sol_p):
                    all_solicitations[ifname] = read_sysctl_int(sol_p)
                if os.path.isfile(int_p):
                    all_intervals[ifname] = read_sysctl_int(int_p)
                if os.path.isfile(del_p):
                    all_delays[ifname] = read_sysctl_int(del_p)
                if os.path.isfile(max_p):
                    all_max_intervals[ifname] = read_sysctl_int(max_p)

    snmp6_stats = parse_snmp6(snmp6_path)
    in_rs = snmp6_stats.get("Icmp6InRouterSolicits", 0)
    out_rs = snmp6_stats.get("Icmp6OutRouterSolicits", 0)
    in_ra = snmp6_stats.get("Icmp6InRouterAdvertisements", 0)
    out_ra = snmp6_stats.get("Icmp6OutRouterAdvertisements", 0)

    issues: List[str] = []
    status = "HEALTHY"

    # Loopback interface must not have positive router solicitations
    lo_sol = all_solicitations.get("lo", -1)
    if lo_sol > 0:
        issues.append(
            f"Loopback interface has active router solicitations enabled (router_solicitations={lo_sol} on lo); "
            "risk of spurious local loopback RS emissions"
        )
        status = "WARNING"

    # Check for aggressive RS intervals (< floor)
    aggressive_ifaces: List[str] = []
    for ifname, interval in all_intervals.items():
        if interval >= 0 and interval < warn_rs_interval_floor:
            aggressive_ifaces.append(f"{ifname} ({interval}s)")

    if aggressive_ifaces:
        issues.append(
            f"Aggressive Router Solicitation interval below minimum threshold ({warn_rs_interval_floor}s): "
            f"{', '.join(aggressive_ifaces)}"
        )
        status = "WARNING"

    # Check for zero delay on non-lo interfaces (synchronization burst risk)
    zero_delay_ifaces: List[str] = []
    for ifname, delay in all_delays.items():
        if ifname not in ("lo", "all", "default") and delay == 0:
            zero_delay_ifaces.append(ifname)

    if zero_delay_ifaces:
        issues.append(
            f"Zero initial delay before Router Solicitation on interfaces: {', '.join(zero_delay_ifaces)} "
            "(RFC 4861 §6.3.7 synchronization burst risk)"
        )
        if status != "CRITICAL":
            status = "WARNING"

    return {
        "pattern": 260,
        "name": "router_solicit",
        "description": "Host IPv6 Router Solicitation (RS / RFC 4861 / RFC 7559) & ICMPv6 Discovery Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "interfaces_audited": len(all_solicitations),
        "lo_router_solicitations": lo_sol,
        "default_router_solicitation_interval": all_intervals.get("default", 4),
        "default_router_solicitation_delay": all_delays.get("default", 1),
        "default_router_solicitation_max_interval": all_max_intervals.get("default", 3600),
        "in_router_solicits": in_rs,
        "out_router_solicits": out_rs,
        "in_router_advertisements": in_ra,
        "out_router_advertisements": out_ra,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Host IPv6 Router Solicitation (RS / RFC 4861 / RFC 7559) & ICMPv6 Discovery Guard (Pattern 260)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    parser.add_argument("--conf-dir", default=CONF_IPV6_BASE, help="Path to /proc/sys/net/ipv6/conf directory")
    parser.add_argument("--snmp6-file", default=PROC_SNMP6, help="Path to /proc/net/snmp6")
    parser.add_argument(
        "--warn-rs-interval-floor", type=int, default=1, help="Warning threshold floor for RS interval in seconds"
    )

    args = parser.parse_args()

    report = audit_router_solicit_guard(
        conf_dir=args.conf_dir,
        snmp6_path=args.snmp6_file,
        warn_rs_interval_floor=args.warn_rs_interval_floor,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Pattern 260: {report['name']} - Status: {report['status']}")
        print(f"  interfaces_audited: {report['interfaces_audited']}")
        print(f"  lo_router_solicitations: {report['lo_router_solicitations']}")
        print(f"  default_router_solicitation_interval: {report['default_router_solicitation_interval']}s")
        print(f"  default_router_solicitation_delay: {report['default_router_solicitation_delay']}s")
        print(f"  out_router_solicits: {report['out_router_solicits']}")
        print(f"  in_router_advertisements: {report['in_router_advertisements']}")
        if report["issues"]:
            print("  Issues:")
            for issue in report["issues"]:
                print(f"    - {issue}")
        else:
            print("  Issues: none (nominal)")

    return 0 if report["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
