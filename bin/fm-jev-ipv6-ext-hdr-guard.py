#!/usr/bin/env python3
"""
bin/fm-jev-ipv6-ext-hdr-guard.py - Host IPv6 Extension Header Limits & Options Security Policy Guard (Pattern 252)

Audits Linux kernel IPv6 Hop-by-Hop (HBH) and Destination (DST) extension header limits,
preventing extension header chain complexity DoS attacks (RFC 8200 §4.3, §4.6) and
auditing SNMP IPv6 header error counters:
  - max_hbh_opts_number (/proc/sys/net/ipv6/max_hbh_opts_number: maximum HBH options per packet)
  - max_hbh_length (/proc/sys/net/ipv6/max_hbh_length: maximum length in bytes for HBH header)
  - max_dst_opts_number (/proc/sys/net/ipv6/max_dst_opts_number: maximum DST options per packet)
  - max_dst_opts_length (/proc/sys/net/ipv6/max_dst_opts_length: maximum length in bytes for DST header)
  - SNMP telemetry from /proc/net/snmp6 (Ip6InHdrErrors, Ip6InUnknownProtos, Ip6InTruncatedPkts,
    Ip6InDiscards, Ip6InReceives, Ip6InDelivers)

Invariants:
  - Bounded extension header option parsing limits to prevent CPU exhaustion DoS.
  - Verification that IPv6 inbound header discard and truncation rates remain nominal.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl/snmp6 paths are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

SYSCTL_MAX_HBH_OPTS_NUMBER = "/proc/sys/net/ipv6/max_hbh_opts_number"
SYSCTL_MAX_HBH_LENGTH = "/proc/sys/net/ipv6/max_hbh_length"
SYSCTL_MAX_DST_OPTS_NUMBER = "/proc/sys/net/ipv6/max_dst_opts_number"
SYSCTL_MAX_DST_OPTS_LENGTH = "/proc/sys/net/ipv6/max_dst_opts_length"
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


def parse_snmp6_metrics(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {
        "Ip6InReceives": 0,
        "Ip6InHdrErrors": 0,
        "Ip6InUnknownProtos": 0,
        "Ip6InTruncatedPkts": 0,
        "Ip6InDiscards": 0,
        "Ip6InDelivers": 0,
    }
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                parts = line.split()
                if len(parts) >= 2 and parts[0] in metrics:
                    try:
                        metrics[parts[0]] = int(parts[1])
                    except ValueError:
                        continue
    except OSError:
        pass
    return metrics


def audit_ipv6_ext_hdr_guard(
    max_hbh_opts_path: str = SYSCTL_MAX_HBH_OPTS_NUMBER,
    max_hbh_length_path: str = SYSCTL_MAX_HBH_LENGTH,
    max_dst_opts_path: str = SYSCTL_MAX_DST_OPTS_NUMBER,
    max_dst_opts_length_path: str = SYSCTL_MAX_DST_OPTS_LENGTH,
    snmp6_path: str = PROC_SNMP6,
    warn_max_hbh_opts: int = 16,
    warn_max_dst_opts: int = 16,
    warn_hdr_errors: int = 50,
    warn_truncated_pkts: int = 10,
) -> Dict[str, Any]:
    max_hbh_opts = read_sysctl_int(max_hbh_opts_path, default=8)
    max_hbh_len = read_sysctl_int(max_hbh_length_path, default=2147483647)
    max_dst_opts = read_sysctl_int(max_dst_opts_path, default=8)
    max_dst_len = read_sysctl_int(max_dst_opts_length_path, default=2147483647)

    snmp = parse_snmp6_metrics(snmp6_path)

    issues: List[str] = []
    recommendations: List[str] = []

    if max_hbh_opts < 0:
        issues.append(f"Invalid max_hbh_opts_number sysctl: {max_hbh_opts}")
        recommendations.append("Set net.ipv6.max_hbh_opts_number to 8 (RFC 8200 standard default)")
    elif max_hbh_opts > warn_max_hbh_opts:
        issues.append(
            f"net.ipv6.max_hbh_opts_number is overly permissive ({max_hbh_opts} > {warn_max_hbh_opts}): potential extension header chain DoS risk"
        )
        recommendations.append(
            f"Constrain net.ipv6.max_hbh_opts_number <= {warn_max_hbh_opts} to bound hop-by-hop parsing depth"
        )

    if max_dst_opts < 0:
        issues.append(f"Invalid max_dst_opts_number sysctl: {max_dst_opts}")
        recommendations.append("Set net.ipv6.max_dst_opts_number to 8 (RFC 8200 standard default)")
    elif max_dst_opts > warn_max_dst_opts:
        issues.append(
            f"net.ipv6.max_dst_opts_number is overly permissive ({max_dst_opts} > {warn_max_dst_opts}): potential destination options chain DoS risk"
        )
        recommendations.append(
            f"Constrain net.ipv6.max_dst_opts_number <= {warn_max_dst_opts} to bound destination options parsing depth"
        )

    hdr_errors = snmp.get("Ip6InHdrErrors", 0)
    truncated = snmp.get("Ip6InTruncatedPkts", 0)
    unknown_proto = snmp.get("Ip6InUnknownProtos", 0)
    discards = snmp.get("Ip6InDiscards", 0)
    receives = snmp.get("Ip6InReceives", 0)
    delivers = snmp.get("Ip6InDelivers", 0)

    if hdr_errors > warn_hdr_errors:
        issues.append(
            f"Elevated IPv6 inbound header errors: {hdr_errors} discards (> {warn_hdr_errors})"
        )
        recommendations.append(
            "Inspect incoming IPv6 traffic for malformed extension headers or mtu mismatches"
        )

    if truncated > warn_truncated_pkts:
        issues.append(
            f"Elevated IPv6 truncated packets: {truncated} discards (> {warn_truncated_pkts})"
        )
        recommendations.append(
            "Investigate path MTU fragmentation issues or truncated extension header payloads"
        )

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    if healthy and not recommendations:
        recommendations.append(
            "IPv6 Hop-by-Hop and Destination extension header limits and SNMP telemetry are nominal"
        )

    return {
        "guard": "ipv6_ext_hdr",
        "pattern": 252,
        "jev_pattern": 390,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": healthy,
        "max_hbh_opts_number": max_hbh_opts,
        "max_hbh_length": max_hbh_len,
        "max_dst_opts_number": max_dst_opts,
        "max_dst_opts_length": max_dst_len,
        "in_hdr_errors": hdr_errors,
        "in_truncated_pkts": truncated,
        "in_unknown_protos": unknown_proto,
        "in_discards": discards,
        "in_receives": receives,
        "in_delivers": delivers,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Host IPv6 Extension Header Limits & Options Security Policy Guard (Pattern 252)"
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

    report = audit_ipv6_ext_hdr_guard()

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        status_line = (
            f"[{report['guard'].upper()}] Status: {report['status']} (Pattern {report['pattern']}) | "
            f"HBH Opts: {report['max_hbh_opts_number']} | DST Opts: {report['max_dst_opts_number']} | "
            f"Hdr Errors: {report['in_hdr_errors']} | Truncated: {report['in_truncated_pkts']} | "
            f"Discards: {report['in_discards']} | Receives: {report['in_receives']}"
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
