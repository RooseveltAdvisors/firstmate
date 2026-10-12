#!/usr/bin/env python3
"""
bin/fm-jev-mld-guard.py - Host IPv6 Multicast Listener Discovery (MLD / RFC 3810 / RFC 2710) Guard (Pattern 263 / Pattern 401)

Audits Linux kernel IPv6 Multicast Listener Discovery (MLD) parameters and telemetry:
  - conf/*/mldv1_unsolicited_report_interval: MLDv1 unsolicited report interval in ms (default 10000ms)
  - conf/*/mldv2_unsolicited_report_interval: MLDv2 unsolicited report interval in ms (default 1000ms)
  - conf/*/force_mld_version: 0=auto, 1=force MLDv1, 2=force MLDv2
  - /proc/sys/net/ipv6/mld_qrv: Querier Robustness Variable (RFC 3810 §9.1, default 2)
  - /proc/sys/net/ipv6/mld_max_msf: Max multicast source filters (default 64)
  - /proc/net/snmp6: MLD / ICMPv6 membership queries and report metrics

Invariants:
  - QRV (Querier Robustness Variable) must be >= 1 to prevent multicast state drop on transient packet loss.
  - Report intervals must maintain sufficient backoff (floor >= 100ms) to prevent MLD query report storms.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths or snmp6 are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

CONF_IPV6_BASE = "/proc/sys/net/ipv6/conf"
PROC_SYS_IPV6_BASE = "/proc/sys/net/ipv6"
PROC_SNMP6 = "/proc/net/snmp6"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content else default
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


def audit_mld_guard(
    conf_dir: str = CONF_IPV6_BASE,
    ipv6_sys_dir: str = PROC_SYS_IPV6_BASE,
    snmp6_path: str = PROC_SNMP6,
    min_v2_interval_ms: int = 100,
) -> Dict[str, Any]:
    all_v1_intervals: Dict[str, int] = {}
    all_v2_intervals: Dict[str, int] = {}
    all_force_versions: Dict[str, int] = {}

    if os.path.isdir(conf_dir):
        for entry in os.listdir(conf_dir):
            iface_path = os.path.join(conf_dir, entry)
            if os.path.isdir(iface_path):
                ifname = entry
                v1_p = os.path.join(iface_path, "mldv1_unsolicited_report_interval")
                v2_p = os.path.join(iface_path, "mldv2_unsolicited_report_interval")
                force_p = os.path.join(iface_path, "force_mld_version")

                if os.path.isfile(v1_p):
                    all_v1_intervals[ifname] = read_sysctl_int(v1_p)
                if os.path.isfile(v2_p):
                    all_v2_intervals[ifname] = read_sysctl_int(v2_p)
                if os.path.isfile(force_p):
                    all_force_versions[ifname] = read_sysctl_int(force_p)

    mld_qrv = read_sysctl_int(os.path.join(ipv6_sys_dir, "mld_qrv"), default=2)
    mld_max_msf = read_sysctl_int(os.path.join(ipv6_sys_dir, "mld_max_msf"), default=64)

    snmp6_metrics = parse_snmp6(snmp6_path)
    in_mldv2_reports = snmp6_metrics.get("Icmp6InMLDv2Reports", 0)
    in_queries = snmp6_metrics.get("Icmp6InGroupMembQueries", 0)
    in_responses = snmp6_metrics.get("Icmp6InGroupMembResponses", 0)
    in_reductions = snmp6_metrics.get("Icmp6InGroupMembReductions", 0)

    issues: List[str] = []
    status = "HEALTHY"

    # QRV check (RFC 3810 §9.1)
    if mld_qrv < 1:
        issues.append(
            f"Invalid or fragile MLD Querier Robustness Variable (mld_qrv={mld_qrv}); "
            "RFC 3810 mandates QRV >= 1 to prevent multicast state drop on transient loss"
        )
        status = "WARNING"

    # Check for aggressive unsolicited report intervals (< floor)
    aggressive_ifaces: List[str] = []
    for ifname, intvl in all_v2_intervals.items():
        if intvl >= 0 and intvl < min_v2_interval_ms:
            aggressive_ifaces.append(f"{ifname} ({intvl}ms)")

    if aggressive_ifaces:
        issues.append(
            f"Aggressive MLDv2 unsolicited report interval below minimum threshold ({min_v2_interval_ms}ms): "
            f"{', '.join(aggressive_ifaces)} (risk of multicast report storms)"
        )
        status = "WARNING"

    return {
        "pattern": 263,
        "name": "mld",
        "description": "Host IPv6 Multicast Listener Discovery (MLD / RFC 3810 / RFC 2710) Parameters & Query Robustness Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.timezone.utc and datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "interfaces_audited": len(all_v2_intervals),
        "mld_qrv": mld_qrv,
        "mld_max_msf": mld_max_msf,
        "default_mldv1_interval_ms": all_v1_intervals.get("default", 10000),
        "default_mldv2_interval_ms": all_v2_intervals.get("default", 1000),
        "default_force_mld_version": all_force_versions.get("default", 0),
        "in_mldv2_reports": in_mldv2_reports,
        "in_group_membership_queries": in_queries,
        "in_group_membership_responses": in_responses,
        "in_group_membership_reductions": in_reductions,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Host IPv6 Multicast Listener Discovery (MLD / RFC 3810 / RFC 2710) Guard (Pattern 263 / Pattern 401)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    parser.add_argument("--conf-dir", default=CONF_IPV6_BASE, help="Path to /proc/sys/net/ipv6/conf directory")
    parser.add_argument("--ipv6-sys-dir", default=PROC_SYS_IPV6_BASE, help="Path to /proc/sys/net/ipv6 directory")
    parser.add_argument("--snmp6-file", default=PROC_SNMP6, help="Path to /proc/net/snmp6")
    parser.add_argument(
        "--min-v2-interval-ms", type=int, default=100, help="Minimum MLDv2 unsolicited report interval floor in ms"
    )

    args = parser.parse_args()

    report = audit_mld_guard(
        conf_dir=args.conf_dir,
        ipv6_sys_dir=args.ipv6_sys_dir,
        snmp6_path=args.snmp6_file,
        min_v2_interval_ms=args.min_v2_interval_ms,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Pattern 263: {report['name']} - Status: {report['status']}")
        print(f"  interfaces_audited: {report['interfaces_audited']}")
        print(f"  mld_qrv: {report['mld_qrv']}")
        print(f"  mld_max_msf: {report['mld_max_msf']}")
        print(f"  default_mldv1_interval_ms: {report['default_mldv1_interval_ms']}ms")
        print(f"  default_mldv2_interval_ms: {report['default_mldv2_interval_ms']}ms")
        print(f"  default_force_mld_version: {report['default_force_mld_version']}")
        print(f"  in_mldv2_reports: {report['in_mldv2_reports']}")
        print(f"  in_group_membership_queries: {report['in_group_membership_queries']}")
        if report["issues"]:
            print("  Issues:")
            for issue in report["issues"]:
                print(f"    - {issue}")
        else:
            print("  Issues: none (nominal)")

    return 0 if report["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
