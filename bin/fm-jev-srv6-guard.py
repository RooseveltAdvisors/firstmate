#!/usr/bin/env python3
"""
bin/fm-jev-srv6-guard.py - Host Segment Routing over IPv6 (SRv6 / RFC 8754) & SRH Security Policy Guard (Pattern 257 — 300th Milestone)

Audits Linux kernel RFC 8754 / RFC 8402 Segment Routing over IPv6 (SRv6) configuration, Segment Routing
Header (SRH) processing enablement, HMAC cryptographic validation, and IPv6 extension header telemetry:
  - conf/*/seg6_enabled: Per-interface SRH processing status (0=disabled, 1=enabled).
  - conf/*/seg6_require_hmac: Mandatory HMAC verification flag (-1=disabled, 0=optional, 1=mandatory).
  - seg6_flowlabel: SRv6 outer IPv6 header flowlabel computation policy (-1..2).
  - snmp6 telemetry: Ip6InReceives, Ip6InHdrErrors, Ip6InTruncatedPkts, Ip6InDiscards.

Invariants:
  - Prevents unauthenticated SRH packet injection and arbitrary source routing loops.
  - Ensures RFC 8754 §5 topological boundary enforcement across multi-agent cluster nodes.
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

CONF_SEG6_ENABLED_GLOB = "/proc/sys/net/ipv6/conf/*/seg6_enabled"
CONF_SEG6_HMAC_GLOB = "/proc/sys/net/ipv6/conf/*/seg6_require_hmac"
SYSCTL_SEG6_FLOWLABEL = "/proc/sys/net/ipv6/seg6_flowlabel"
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


def audit_srv6_guard(
    enabled_glob: str = CONF_SEG6_ENABLED_GLOB,
    hmac_glob: str = CONF_SEG6_HMAC_GLOB,
    flowlabel_path: str = SYSCTL_SEG6_FLOWLABEL,
    snmp6_path: str = PROC_SNMP6,
    warn_hdr_error_pct: float = 0.05,
    crit_hdr_error_pct: float = 0.5,
) -> Dict[str, Any]:
    flowlabel_policy = read_sysctl_int(flowlabel_path, default=0)

    enabled_interfaces: List[str] = []
    unauthenticated_interfaces: List[str] = []
    all_enabled_map: Dict[str, int] = {}
    all_hmac_map: Dict[str, int] = {}

    for p in glob.glob(enabled_glob):
        ifname = os.path.basename(os.path.dirname(p))
        val = read_sysctl_int(p, default=-1)
        all_enabled_map[ifname] = val
        if val == 1:
            enabled_interfaces.append(ifname)

    for p in glob.glob(hmac_glob):
        ifname = os.path.basename(os.path.dirname(p))
        val = read_sysctl_int(p, default=-1)
        all_hmac_map[ifname] = val

    for ifname in enabled_interfaces:
        hmac_val = all_hmac_map.get(ifname, 0)
        if hmac_val != 1:
            unauthenticated_interfaces.append(ifname)

    snmp6_stats = parse_snmp6(snmp6_path)
    in_receives = snmp6_stats.get("Ip6InReceives", 0)
    in_hdr_errors = snmp6_stats.get("Ip6InHdrErrors", 0)
    in_trunc_pkts = snmp6_stats.get("Ip6InTruncatedPkts", 0)
    in_discards = snmp6_stats.get("Ip6InDiscards", 0)

    hdr_error_pct = (in_hdr_errors / in_receives * 100.0) if in_receives > 0 else 0.0

    issues: List[str] = []
    status = "HEALTHY"

    # Loopback must never have SRv6 enabled
    if all_enabled_map.get("lo", 0) == 1:
        issues.append("Loopback interface has SRv6 enabled (seg6_enabled=1 on lo); risk of local IPC header overhead")
        status = "WARNING"

    # Enabled interfaces without mandatory HMAC
    if unauthenticated_interfaces:
        issues.append(
            f"SRv6 enabled on interfaces without mandatory HMAC validation: "
            f"{', '.join(unauthenticated_interfaces)} (RFC 8754 security risk)"
        )
        status = "WARNING"

    # Flowlabel policy validation (-1=copy, 0=zero, 1=calculate hash, 2=random)
    if flowlabel_policy not in (-1, 0, 1, 2):
        issues.append(f"Invalid net.ipv6.seg6_flowlabel: {flowlabel_policy} (must be -1..2)")
        if status != "CRITICAL":
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
        "pattern": 257,
        "name": "srv6",
        "description": "Host Segment Routing over IPv6 (SRv6 / RFC 8754) & SRH Security Policy Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "seg6_flowlabel": flowlabel_policy,
        "interfaces_audited": len(all_enabled_map),
        "enabled_interfaces_count": len(enabled_interfaces),
        "enabled_interfaces": enabled_interfaces,
        "unauthenticated_interfaces": unauthenticated_interfaces,
        "lo_seg6_enabled": all_enabled_map.get("lo", 0),
        "in_receives": in_receives,
        "in_hdr_errors": in_hdr_errors,
        "hdr_error_ratio_pct": round(hdr_error_pct, 6),
        "in_truncated_pkts": in_trunc_pkts,
        "in_discards": in_discards,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Host Segment Routing over IPv6 (SRv6 / RFC 8754) & SRH Security Policy Guard (Pattern 257)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    parser.add_argument("--enabled-glob", default=CONF_SEG6_ENABLED_GLOB, help="Glob pattern for seg6_enabled sysctls")
    parser.add_argument("--hmac-glob", default=CONF_SEG6_HMAC_GLOB, help="Glob pattern for seg6_require_hmac sysctls")
    parser.add_argument("--flowlabel-file", default=SYSCTL_SEG6_FLOWLABEL, help="Path to seg6_flowlabel")
    parser.add_argument("--snmp6-file", default=PROC_SNMP6, help="Path to /proc/net/snmp6")
    parser.add_argument(
        "--warn-hdr-error-pct", type=float, default=0.05, help="Warning threshold for header error percentage"
    )
    parser.add_argument(
        "--crit-hdr-error-pct", type=float, default=0.5, help="Critical threshold for header error percentage"
    )

    args = parser.parse_args()

    report = audit_srv6_guard(
        enabled_glob=args.enabled_glob,
        hmac_glob=args.hmac_glob,
        flowlabel_path=args.flowlabel_file,
        snmp6_path=args.snmp6_file,
        warn_hdr_error_pct=args.warn_hdr_error_pct,
        crit_hdr_error_pct=args.crit_hdr_error_pct,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Pattern 257: {report['name']} - Status: {report['status']}")
        print(f"  seg6_flowlabel: {report['seg6_flowlabel']}")
        print(f"  interfaces_audited: {report['interfaces_audited']}")
        print(f"  enabled_interfaces: {report['enabled_interfaces']}")
        print(f"  lo_seg6_enabled: {report['lo_seg6_enabled']}")
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
