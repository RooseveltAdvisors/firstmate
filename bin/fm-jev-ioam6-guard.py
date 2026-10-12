#!/usr/bin/env python3
"""
bin/fm-jev-ioam6-guard.py - Host IPv6 In-situ OAM (IOAM) Telemetry & Encapsulation Guard (Pattern 255)

Audits Linux kernel RFC 9197 / RFC 9359 In-situ OAM (IOAM) for IPv6 configuration and extension header integrity:
  - ioam6_id: 24-bit IOAM node ID (default 16,777,215 = 0xFFFFFF, unassigned).
  - ioam6_id_wide: 56-bit wide IOAM node ID (default 72,057,594,037,927,935 = 0xFFFFFFFFFFFFFF).
  - conf/*/ioam6_enabled: Per-interface IOAM processing status (0=disabled, 1=enabled).
  - snmp6 telemetry: Ip6InReceives, Ip6InHdrErrors, Ip6InTruncatedPkts, Ip6InDiscards.

Invariants:
  - Prevents accidental IOAM telemetry injection or unassigned node ID encapsulation.
  - Verifies loopback interface never has IOAM enabled to avoid IPC overhead.
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

SYSCTL_IOAM6_ID = "/proc/sys/net/ipv6/ioam6_id"
SYSCTL_IOAM6_ID_WIDE = "/proc/sys/net/ipv6/ioam6_id_wide"
CONF_IPV6_GLOB = "/proc/sys/net/ipv6/conf/*/ioam6_enabled"
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


def audit_ioam6_guard(
    ioam6_id_path: str = SYSCTL_IOAM6_ID,
    ioam6_id_wide_path: str = SYSCTL_IOAM6_ID_WIDE,
    conf_glob: str = CONF_IPV6_GLOB,
    snmp6_path: str = PROC_SNMP6,
    warn_hdr_error_pct: float = 0.05,
    crit_hdr_error_pct: float = 0.5,
) -> Dict[str, Any]:
    ioam6_id = read_sysctl_int(ioam6_id_path, default=16777215)
    ioam6_id_wide = read_sysctl_int(ioam6_id_wide_path, default=72057594037927935)

    enabled_interfaces: List[str] = []
    all_interfaces: Dict[str, int] = {}

    for p in glob.glob(conf_glob):
        ifname = os.path.basename(os.path.dirname(p))
        val = read_sysctl_int(p, default=-1)
        all_interfaces[ifname] = val
        if val == 1:
            enabled_interfaces.append(ifname)

    snmp6_stats = parse_snmp6(snmp6_path)
    in_receives = snmp6_stats.get("Ip6InReceives", 0)
    in_hdr_errors = snmp6_stats.get("Ip6InHdrErrors", 0)
    in_trunc_pkts = snmp6_stats.get("Ip6InTruncatedPkts", 0)
    in_discards = snmp6_stats.get("Ip6InDiscards", 0)

    hdr_error_pct = (in_hdr_errors / in_receives * 100.0) if in_receives > 0 else 0.0

    issues: List[str] = []
    status = "HEALTHY"

    # Validate node ID bounds (24-bit: 0 to 16,777,215)
    if ioam6_id < 0 or ioam6_id > 16777215:
        issues.append(f"Invalid net.ipv6.ioam6_id: {ioam6_id} (must be 0..16777215)")
        status = "WARNING"

    # Validate wide node ID bounds (56-bit: 0 to 72,057,594,037,927,935)
    if ioam6_id_wide < 0 or ioam6_id_wide > 72057594037927935:
        issues.append(f"Invalid net.ipv6.ioam6_id_wide: {ioam6_id_wide} (must be 0..72057594037927935)")
        status = "WARNING"

    # Loopback must never have IOAM enabled
    if all_interfaces.get("lo", 0) == 1:
        issues.append("Loopback interface has IOAM enabled (ioam6_enabled=1 on lo); risk of IPC header overhead")
        status = "WARNING"

    # Header error check
    if hdr_error_pct >= crit_hdr_error_pct:
        issues.append(
            f"Critical IPv6 header error rate: {hdr_error_pct:.4f}% "
            f"({in_hdr_errors:,} / {in_receives:,} packets)"
        )
        status = "CRITICAL"
    elif hdr_error_pct >= warn_hdr_error_pct:
        issues.append(
            f"Elevated IPv6 header error rate: {hdr_error_pct:.4f}% "
            f"({in_hdr_errors:,} / {in_receives:,} packets)"
        )
        if status != "CRITICAL":
            status = "WARNING"

    return {
        "pattern": 255,
        "name": "ioam6",
        "description": "Host IPv6 In-situ OAM (IOAM) Telemetry & Encapsulation Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "ioam6_id": ioam6_id,
        "ioam6_id_wide": ioam6_id_wide,
        "interfaces_audited": len(all_interfaces),
        "enabled_interfaces_count": len(enabled_interfaces),
        "enabled_interfaces": enabled_interfaces,
        "lo_ioam6_enabled": all_interfaces.get("lo", 0),
        "in_receives": in_receives,
        "in_hdr_errors": in_hdr_errors,
        "hdr_error_ratio_pct": round(hdr_error_pct, 6),
        "in_truncated_pkts": in_trunc_pkts,
        "in_discards": in_discards,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Host IPv6 In-situ OAM (IOAM) Telemetry & Encapsulation Guard (Pattern 255)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    parser.add_argument("--ioam6-id-file", default=SYSCTL_IOAM6_ID, help="Path to ioam6_id")
    parser.add_argument("--ioam6-id-wide-file", default=SYSCTL_IOAM6_ID_WIDE, help="Path to ioam6_id_wide")
    parser.add_argument("--conf-glob", default=CONF_IPV6_GLOB, help="Glob pattern for ioam6_enabled sysctls")
    parser.add_argument("--snmp6-file", default=PROC_SNMP6, help="Path to /proc/net/snmp6")
    parser.add_argument("--warn-hdr-error-pct", type=float, default=0.05, help="Warning threshold for header error percentage")
    parser.add_argument("--crit-hdr-error-pct", type=float, default=0.5, help="Critical threshold for header error percentage")

    args = parser.parse_args()

    report = audit_ioam6_guard(
        ioam6_id_path=args.ioam6_id_file,
        ioam6_id_wide_path=args.ioam6_id_wide_file,
        conf_glob=args.conf_glob,
        snmp6_path=args.snmp6_file,
        warn_hdr_error_pct=args.warn_hdr_error_pct,
        crit_hdr_error_pct=args.crit_hdr_error_pct,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Pattern 255: {report['name']} - Status: {report['status']}")
        print(f"  ioam6_id: {report['ioam6_id']}")
        print(f"  ioam6_id_wide: {report['ioam6_id_wide']}")
        print(f"  interfaces_audited: {report['interfaces_audited']}")
        print(f"  enabled_interfaces: {report['enabled_interfaces']}")
        print(f"  lo_ioam6_enabled: {report['lo_ioam6_enabled']}")
        print(f"  in_receives: {report['in_receives']}")
        print(f"  in_hdr_errors: {report['in_hdr_errors']} ({report['hdr_error_ratio_pct']}%)")
        print(f"  in_discards: {report['in_discards']}")
        if report["issues"]:
            print("  Issues:")
            for issue in report["issues"]:
                print(f"    - {issue}")
        else:
            print("  Issues: none (nominal)")

    return 0 if report["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
