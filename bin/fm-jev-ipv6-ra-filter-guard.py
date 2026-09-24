#!/usr/bin/env python3
"""
bin/fm-jev-ipv6-ra-filter-guard.py - Host IPv6 Router Advertisement (RA) Hop Limit & Lifetime Filter Guard (Pattern 253)

Audits Linux kernel IPv6 Router Advertisement (RA) security filtering parameters:
  - accept_ra_min_hop_limit: Minimum acceptable Hop Limit received in RA (RFC 4861 §6.3.4, default >= 1).
    Prevents rogue RAs from advertising a Hop Limit of 0 or 1, which causes immediate packet expiration.
  - accept_ra_min_lft: Minimum router lifetime in seconds required to accept an RA default route.
    Mitigates rapid route flapping from transient or low-lifetime RA advertisements.
  - accept_ra_rt_info_min_plen / accept_ra_rt_info_max_plen: Route Information Option (RIO) prefix length bounds (RFC 4191).
  - ra_defrtr_metric: Metric assigned to default routes learned from RAs (default 1024).
  - ra_honor_pio_life: Whether to honor prefix lifetime in Prefix Information Options (RFC 4861).
  - ra_honor_pio_pflag: Whether to honor P-flag in PIO.

Invariants:
  - Protection against rogue RA hop-limit reduction and route flap storms.
  - Verification that IPv6 RA prefix length and lifetime filtering policies are intact.
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

CONF_IPV6_ALL = "/proc/sys/net/ipv6/conf/all"
CONF_IPV6_DEFAULT = "/proc/sys/net/ipv6/conf/default"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0])
    except (ValueError, OSError, IndexError):
        return default


def audit_ipv6_ra_filter_guard(
    conf_dir: str = CONF_IPV6_ALL,
    default_conf_dir: str = CONF_IPV6_DEFAULT,
    min_allowed_hop_limit: int = 1,
) -> Dict[str, Any]:
    min_hop_limit = read_sysctl_int(os.path.join(conf_dir, "accept_ra_min_hop_limit"), default=1)
    min_lft = read_sysctl_int(os.path.join(conf_dir, "accept_ra_min_lft"), default=0)
    rt_min_plen = read_sysctl_int(os.path.join(conf_dir, "accept_ra_rt_info_min_plen"), default=0)
    rt_max_plen = read_sysctl_int(os.path.join(conf_dir, "accept_ra_rt_info_max_plen"), default=0)
    defrtr_metric = read_sysctl_int(os.path.join(conf_dir, "ra_defrtr_metric"), default=1024)
    honor_pio_life = read_sysctl_int(os.path.join(conf_dir, "ra_honor_pio_life"), default=0)
    honor_pio_pflag = read_sysctl_int(os.path.join(conf_dir, "ra_honor_pio_pflag"), default=0)

    def_min_hop_limit = read_sysctl_int(os.path.join(default_conf_dir, "accept_ra_min_hop_limit"), default=1)
    def_min_lft = read_sysctl_int(os.path.join(default_conf_dir, "accept_ra_min_lft"), default=0)

    issues: List[str] = []
    recommendations: List[str] = []

    if min_hop_limit < min_allowed_hop_limit:
        issues.append(
            f"accept_ra_min_hop_limit is lowered to {min_hop_limit} (< {min_allowed_hop_limit}): "
            "vulnerable to rogue RAs setting Hop Limit to 0 or 1, causing outbound packet expiration"
        )
        recommendations.append(
            f"Set net.ipv6.conf.all.accept_ra_min_hop_limit to at least {min_allowed_hop_limit} (RFC 4861 §6.3.4)"
        )

    if def_min_hop_limit < min_allowed_hop_limit:
        issues.append(
            f"net.ipv6.conf.default.accept_ra_min_hop_limit is lowered to {def_min_hop_limit} (< {min_allowed_hop_limit})"
        )
        recommendations.append(
            f"Set net.ipv6.conf.default.accept_ra_min_hop_limit to at least {min_allowed_hop_limit}"
        )

    if min_lft < 0:
        issues.append(f"Invalid accept_ra_min_lft configuration: {min_lft}")
        recommendations.append("Set net.ipv6.conf.all.accept_ra_min_lft >= 0")

    if rt_max_plen > 0 and rt_min_plen > rt_max_plen:
        issues.append(
            f"Inconsistent RIO prefix limits: accept_ra_rt_info_min_plen ({rt_min_plen}) > "
            f"accept_ra_rt_info_max_plen ({rt_max_plen})"
        )
        recommendations.append(
            "Ensure accept_ra_rt_info_min_plen <= accept_ra_rt_info_max_plen"
        )

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    if healthy and not recommendations:
        recommendations.append(
            "IPv6 Router Advertisement minimum hop limit, lifetime filtering, and RIO prefix policies are nominal"
        )

    return {
        "guard": "ipv6_ra_filter",
        "pattern": 253,
        "jev_pattern": 391,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": healthy,
        "accept_ra_min_hop_limit": min_hop_limit,
        "default_accept_ra_min_hop_limit": def_min_hop_limit,
        "accept_ra_min_lft": min_lft,
        "default_accept_ra_min_lft": def_min_lft,
        "accept_ra_rt_info_min_plen": rt_min_plen,
        "accept_ra_rt_info_max_plen": rt_max_plen,
        "ra_defrtr_metric": defrtr_metric,
        "ra_honor_pio_life": honor_pio_life,
        "ra_honor_pio_pflag": honor_pio_pflag,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Host IPv6 Router Advertisement (RA) Hop Limit & Lifetime Filter Guard (Pattern 253)"
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output full telemetry report in JSON format",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress output if status is HEALTHY and exit with code 0",
    )
    args = parser.parse_args()

    report = audit_ipv6_ra_filter_guard()

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        status_line = (
            f"[{report['guard'].upper()}] Status: {report['status']} (Pattern {report['pattern']}) | "
            f"Min Hop Limit: {report['accept_ra_min_hop_limit']} | Min Lifetime: {report['accept_ra_min_lft']}s | "
            f"Defrtr Metric: {report['ra_defrtr_metric']} | PIO Honor Life: {report['ra_honor_pio_life']}"
        )
        if not args.quiet or not report["healthy"]:
            print(status_line)
            if report["issues"]:
                print("  Issues:")
                for iss in report["issues"]:
                    print(f"    - {iss}")
            if report["recommendations"]:
                print("  Recommendations:")
                for rec in report["recommendations"]:
                    print(f"    - {rec}")

    sys.exit(0 if report["healthy"] else 1)


if __name__ == "__main__":
    main()
