#!/usr/bin/env python3
"""
bin/fm-jev-mcfilter-guard.py - Host Network Source-Specific Multicast (SSM) & IGMP/MLD Socket Filter Guard (Pattern 242)

Audits Linux kernel IPv4 and IPv6 multicast source-specific filtering tables and socket membership limits:
  - /proc/net/mcfilter (IPv4 source filter table: dev, group address, source address, include/exclude counts)
  - /proc/net/mcfilter6 (IPv6 source filter table: dev, multicast address, source address, include/exclude counts)
  - /proc/sys/net/ipv4/igmp_max_memberships (maximum multicast group memberships per socket)
  - /proc/sys/net/ipv4/igmp_max_msf (maximum source filter entries per group for IPv4/IGMPv3)
  - /proc/sys/net/ipv6/mld_max_msf (maximum source filter entries per group for IPv6/MLDv2)

Prevents ENOBUFS socket subscription drops, multicast split-brain during agent service discovery,
and filter table corruption across multi-agent cluster mesh deployments.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysfs/procfs files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Tuple

DEFAULT_MCFILTER_PATH = "/proc/net/mcfilter"
DEFAULT_MCFILTER6_PATH = "/proc/net/mcfilter6"
DEFAULT_SYS_IPV4_PATH = "/proc/sys/net/ipv4"
DEFAULT_SYS_IPV6_PATH = "/proc/sys/net/ipv6"

WARN_MIN_IGMP_MAX_MEMBERSHIPS = 10
WARN_MIN_IGMP_MAX_MSF = 5
WARN_MIN_MLD_MAX_MSF = 10


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception:
        return default


def parse_proc_net_mcfilter(path: str = DEFAULT_MCFILTER_PATH) -> List[Dict[str, Any]]:
    entries: List[Dict[str, Any]] = []
    if not os.path.exists(path):
        return entries
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.read().strip().splitlines()
        if len(lines) <= 1:
            return entries
        for line in lines[1:]:
            parts = line.split()
            if len(parts) >= 6:
                try:
                    entries.append({
                        "idx": int(parts[0]),
                        "device": parts[1],
                        "mca": parts[2],
                        "src": parts[3],
                        "inc": int(parts[4]),
                        "exc": int(parts[5]),
                    })
                except ValueError:
                    continue
    except Exception:
        pass
    return entries


def parse_proc_net_mcfilter6(path: str = DEFAULT_MCFILTER6_PATH) -> List[Dict[str, Any]]:
    entries: List[Dict[str, Any]] = []
    if not os.path.exists(path):
        return entries
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.read().strip().splitlines()
        if len(lines) <= 1:
            return entries
        for line in lines[1:]:
            parts = line.split()
            if len(parts) >= 6:
                try:
                    entries.append({
                        "idx": int(parts[0]),
                        "device": parts[1],
                        "multicast_address": parts[2],
                        "source_address": parts[3],
                        "inc": int(parts[4]),
                        "exc": int(parts[5]),
                    })
                except ValueError:
                    continue
    except Exception:
        pass
    return entries


def audit_mcfilter(
    mcfilter_path: str = DEFAULT_MCFILTER_PATH,
    mcfilter6_path: str = DEFAULT_MCFILTER6_PATH,
    sys_ipv4_path: str = DEFAULT_SYS_IPV4_PATH,
    sys_ipv6_path: str = DEFAULT_SYS_IPV6_PATH,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []

    mcfilter_entries = parse_proc_net_mcfilter(mcfilter_path)
    mcfilter6_entries = parse_proc_net_mcfilter6(mcfilter6_path)

    igmp_max_memberships = read_sysctl_int(os.path.join(sys_ipv4_path, "igmp_max_memberships"), default=20)
    igmp_max_msf = read_sysctl_int(os.path.join(sys_ipv4_path, "igmp_max_msf"), default=10)
    mld_max_msf = read_sysctl_int(os.path.join(sys_ipv6_path, "mld_max_msf"), default=64)

    # Audit sysctl constraints
    if igmp_max_memberships != -1 and igmp_max_memberships < WARN_MIN_IGMP_MAX_MEMBERSHIPS:
        issues.append(
            f"Constrained IGMP max group memberships: {igmp_max_memberships} < {WARN_MIN_IGMP_MAX_MEMBERSHIPS}"
        )
        recommendations.append(
            f"Increase net.ipv4.igmp_max_memberships to at least {WARN_MIN_IGMP_MAX_MEMBERSHIPS} (recommended: 20-50)"
        )

    if igmp_max_msf != -1 and igmp_max_msf < WARN_MIN_IGMP_MAX_MSF:
        issues.append(
            f"Constrained IGMP source filter entries: {igmp_max_msf} < {WARN_MIN_IGMP_MAX_MSF}"
        )
        recommendations.append(
            f"Increase net.ipv4.igmp_max_msf to at least {WARN_MIN_IGMP_MAX_MSF} (recommended: 10-32)"
        )

    if mld_max_msf != -1 and mld_max_msf < WARN_MIN_MLD_MAX_MSF:
        issues.append(
            f"Constrained MLD source filter entries: {mld_max_msf} < {WARN_MIN_MLD_MAX_MSF}"
        )
        recommendations.append(
            f"Increase net.ipv6.mld_max_msf to at least {WARN_MIN_MLD_MAX_MSF} (recommended: 64)"
        )

    # Aggregate metrics
    ipv4_total_inc = sum(e.get("inc", 0) for e in mcfilter_entries)
    ipv4_total_exc = sum(e.get("exc", 0) for e in mcfilter_entries)
    ipv6_total_inc = sum(e.get("inc", 0) for e in mcfilter6_entries)
    ipv6_total_exc = sum(e.get("exc", 0) for e in mcfilter6_entries)

    total_ipv4_filters = len(mcfilter_entries)
    total_ipv6_filters = len(mcfilter6_entries)
    total_filters = total_ipv4_filters + total_ipv6_filters

    # Check for individual group source filter saturation
    for e in mcfilter_entries:
        inc_cnt = e.get("inc", 0)
        exc_cnt = e.get("exc", 0)
        total_flt = inc_cnt + exc_cnt
        if igmp_max_msf != -1 and total_flt >= igmp_max_msf:
            issues.append(
                f"IPv4 multicast group {e.get('mca')} on {e.get('device')} reached igmp_max_msf ceiling ({total_flt} >= {igmp_max_msf})"
            )

    for e in mcfilter6_entries:
        inc_cnt = e.get("inc", 0)
        exc_cnt = e.get("exc", 0)
        total_flt = inc_cnt + exc_cnt
        if mld_max_msf != -1 and total_flt >= mld_max_msf:
            issues.append(
                f"IPv6 multicast group {e.get('multicast_address')} on {e.get('device')} reached mld_max_msf ceiling ({total_flt} >= {mld_max_msf})"
            )

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    summary: Dict[str, Any] = {
        "status": status,
        "healthy": healthy,
        "total_filters": total_filters,
        "total_ipv4_filters": total_ipv4_filters,
        "total_ipv6_filters": total_ipv6_filters,
        "ipv4_total_inc": ipv4_total_inc,
        "ipv4_total_exc": ipv4_total_exc,
        "ipv6_total_inc": ipv6_total_inc,
        "ipv6_total_exc": ipv6_total_exc,
        "igmp_max_memberships": igmp_max_memberships,
        "igmp_max_msf": igmp_max_msf,
        "mld_max_msf": mld_max_msf,
        "issues": issues,
    }

    details: Dict[str, Any] = {
        "mcfilter_ipv4_entries": mcfilter_entries,
        "mcfilter_ipv6_entries": mcfilter6_entries,
        "recommendations": recommendations,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "details": details,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network Source-Specific Multicast (SSM) & IGMP/MLD Socket Filter Guard (Pattern 242)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    parser.add_argument("--mcfilter", default=DEFAULT_MCFILTER_PATH, help="Path to /proc/net/mcfilter")
    parser.add_argument("--mcfilter6", default=DEFAULT_MCFILTER6_PATH, help="Path to /proc/net/mcfilter6")
    parser.add_argument("--sys-ipv4", default=DEFAULT_SYS_IPV4_PATH, help="Path to /proc/sys/net/ipv4")
    parser.add_argument("--sys-ipv6", default=DEFAULT_SYS_IPV6_PATH, help="Path to /proc/sys/net/ipv6")
    parser.add_argument("--verbose", action="store_true", help="Print verbose metric details")
    args = parser.parse_args()

    report = audit_mcfilter(
        mcfilter_path=args.mcfilter,
        mcfilter6_path=args.mcfilter6,
        sys_ipv4_path=args.sys_ipv4,
        sys_ipv6_path=args.sys_ipv6,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        summary = report["summary"]
        print(f"[{summary['status']}] Jev Host Multicast Source Filter Guard (Pattern 242)")
        print(f"  Total SSM filters   : {summary['total_filters']} (IPv4: {summary['total_ipv4_filters']}, IPv6: {summary['total_ipv6_filters']})")
        print(f"  IPv4 filters        : inc={summary['ipv4_total_inc']}, exc={summary['ipv4_total_exc']}")
        print(f"  IPv6 filters        : inc={summary['ipv6_total_inc']}, exc={summary['ipv6_total_exc']}")
        print(f"  igmp_max_memberships: {summary['igmp_max_memberships']}")
        print(f"  igmp_max_msf        : {summary['igmp_max_msf']}")
        print(f"  mld_max_msf         : {summary['mld_max_msf']}")
        if summary["issues"]:
            print("  Issues detected:")
            for iss in summary["issues"]:
                print(f"    - {iss}")
        if report["details"]["recommendations"]:
            print("  Recommendations:")
            for rec in report["details"]["recommendations"]:
                print(f"    - {rec}")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
