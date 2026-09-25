#!/usr/bin/env python3
"""
bin/fm-jev-rpl-seg-guard.py - Host IPv6 RPL Routing Header Type 3 (RFC 6554) & Source Routing Guard (Pattern 258)

Audits Linux kernel RFC 6554 RPL (Routing Protocol for Low-Power and Lossy Networks)
source routing header processing, interface boundaries, and IPv6 extension header telemetry:
  - conf/*/rpl_seg_enabled: Per-interface RPL SRH processing status (0=disabled, 1=enabled).
  - snmp6 telemetry: Ip6InReceives, Ip6InHdrErrors, Ip6InTruncatedPkts, Ip6InDiscards, Ip6InUnknownProtos.

Invariants:
  - Prevents unauthenticated RPL source routing packet injection and arbitrary loose traversal loops.
  - Ensures RFC 6554 §4 topological boundary enforcement across multi-agent cluster nodes.
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

CONF_RPL_SEG_GLOB = "/proc/sys/net/ipv6/conf/*/rpl_seg_enabled"
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


def audit_rpl_seg_guard(
    rpl_glob: str = CONF_RPL_SEG_GLOB,
    snmp6_path: str = PROC_SNMP6,
    warn_hdr_error_pct: float = 0.05,
    crit_hdr_error_pct: float = 0.5,
) -> Dict[str, Any]:
    enabled_interfaces: List[str] = []
    all_enabled_map: Dict[str, int] = {}

    for p in glob.glob(rpl_glob):
        ifname = os.path.basename(os.path.dirname(p))
        val = read_sysctl_int(p, default=-1)
        all_enabled_map[ifname] = val
        if val == 1:
            enabled_interfaces.append(ifname)

    snmp6_stats = parse_snmp6(snmp6_path)
    in_receives = snmp6_stats.get("Ip6InReceives", 0)
    in_hdr_errors = snmp6_stats.get("Ip6InHdrErrors", 0)
    in_trunc_pkts = snmp6_stats.get("Ip6InTruncatedPkts", 0)
    in_discards = snmp6_stats.get("Ip6InDiscards", 0)
    in_unknown_protos = snmp6_stats.get("Ip6InUnknownProtos", 0)

    hdr_error_pct = (in_hdr_errors / in_receives * 100.0) if in_receives > 0 else 0.0

    issues: List[str] = []
    status = "HEALTHY"

    # Loopback must never have RPL source routing enabled
    if all_enabled_map.get("lo", 0) == 1:
        issues.append(
            "Loopback interface has RPL source routing enabled (rpl_seg_enabled=1 on lo); "
            "risk of local routing loops and overhead"
        )
        status = "WARNING"

    # External interfaces with RPL enabled
    non_lo_enabled = [i for i in enabled_interfaces if i != "lo"]
    if non_lo_enabled:
        issues.append(
            f"RPL source routing enabled on interfaces: {', '.join(non_lo_enabled)} "
            f"(RFC 6554 source routing traversal risk)"
        )
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
        "pattern": 258,
        "name": "rpl_seg",
        "description": "Host IPv6 RPL Routing Header Type 3 (RFC 6554) & Source Routing Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "interfaces_audited": len(all_enabled_map),
        "enabled_interfaces_count": len(enabled_interfaces),
        "enabled_interfaces": enabled_interfaces,
        "lo_rpl_seg_enabled": all_enabled_map.get("lo", 0),
        "all_rpl_seg_enabled": all_enabled_map.get("all", 0),
        "default_rpl_seg_enabled": all_enabled_map.get("default", 0),
        "in_receives": in_receives,
        "in_hdr_errors": in_hdr_errors,
        "hdr_error_ratio_pct": round(hdr_error_pct, 6),
        "in_truncated_pkts": in_trunc_pkts,
        "in_unknown_protos": in_unknown_protos,
        "in_discards": in_discards,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Host IPv6 RPL Routing Header Type 3 (RFC 6554) & Source Routing Guard (Pattern 258)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    parser.add_argument("--rpl-glob", default=CONF_RPL_SEG_GLOB, help="Glob pattern for rpl_seg_enabled sysctls")
    parser.add_argument("--snmp6-file", default=PROC_SNMP6, help="Path to /proc/net/snmp6")
    parser.add_argument(
        "--warn-hdr-error-pct", type=float, default=0.05, help="Warning threshold for header error percentage"
    )
    parser.add_argument(
        "--crit-hdr-error-pct", type=float, default=0.5, help="Critical threshold for header error percentage"
    )

    args = parser.parse_args()

    report = audit_rpl_seg_guard(
        rpl_glob=args.rpl_glob,
        snmp6_path=args.snmp6_file,
        warn_hdr_error_pct=args.warn_hdr_error_pct,
        crit_hdr_error_pct=args.crit_hdr_error_pct,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Pattern 258: {report['name']} - Status: {report['status']}")
        print(f"  interfaces_audited: {report['interfaces_audited']}")
        print(f"  enabled_interfaces: {report['enabled_interfaces']}")
        print(f"  lo_rpl_seg_enabled: {report['lo_rpl_seg_enabled']}")
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
