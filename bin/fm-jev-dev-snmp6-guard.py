#!/usr/bin/env python3
"""
bin/fm-jev-dev-snmp6-guard.py - Host Network Device Per-Interface IPv6 SNMP Diagnostics Guard (Pattern 243)

Audits per-interface Linux kernel IPv6 (RFC 4293) and ICMPv6 (RFC 4443) statistics:
  - /proc/net/dev_snmp6/<interface> (per-device IPv6 ingress, delivery, header errors, discards, and ICMPv6 metrics)

Provides granular per-device telemetry across multi-agent cluster networks, isolating interface-specific
packet corruption, reassembly stalls, routing blackholes, and MTU too-big discards.

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

DEFAULT_DEV_SNMP6_PATH = "/proc/net/dev_snmp6"

WARN_MAX_HDR_ERROR_RATIO = 0.01      # 1% header error threshold
WARN_MAX_ADDR_ERROR_RATIO = 0.01     # 1% address error threshold
WARN_MAX_REASM_FAIL_RATIO = 0.05     # 5% reassembly failure threshold
WARN_MAX_DISCARD_RATIO = 0.10        # 10% ingress discard threshold for active interfaces


def parse_dev_snmp6_file(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    if not os.path.exists(path):
        return metrics
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.read().strip().splitlines()
        for line in lines:
            parts = line.split()
            if len(parts) >= 2:
                try:
                    metrics[parts[0]] = int(parts[1])
                except ValueError:
                    continue
    except Exception:
        pass
    return metrics


def parse_all_dev_snmp6(base_path: str = DEFAULT_DEV_SNMP6_PATH) -> Dict[str, Dict[str, int]]:
    result: Dict[str, Dict[str, int]] = {}
    if not os.path.isdir(base_path):
        return result
    try:
        for entry in sorted(os.listdir(base_path)):
            full_path = os.path.join(base_path, entry)
            if os.path.isfile(full_path):
                m = parse_dev_snmp6_file(full_path)
                if m:
                    result[entry] = m
    except Exception:
        pass
    return result


def audit_dev_snmp6(base_path: str = DEFAULT_DEV_SNMP6_PATH) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []

    interfaces_data = parse_all_dev_snmp6(base_path)

    total_interfaces = len(interfaces_data)
    total_in_receives = 0
    total_in_delivers = 0
    total_in_discards = 0
    total_in_hdr_errors = 0
    total_in_addr_errors = 0
    total_in_no_routes = 0
    total_icmp6_in_csum_errors = 0
    total_icmp6_in_errors = 0

    interface_summaries: Dict[str, Any] = {}

    for iface, data in interfaces_data.items():
        in_recv = data.get("Ip6InReceives", 0)
        in_deliv = data.get("Ip6InDelivers", 0)
        in_disc = data.get("Ip6InDiscards", 0)
        hdr_err = data.get("Ip6InHdrErrors", 0)
        addr_err = data.get("Ip6InAddrErrors", 0)
        no_route = data.get("Ip6InNoRoutes", 0)
        reasm_reqds = data.get("Ip6ReasmReqds", 0)
        reasm_fails = data.get("Ip6ReasmFails", 0)
        csum_err = data.get("Icmp6InCsumErrors", 0)
        icmp6_err = data.get("Icmp6InErrors", 0)

        total_in_receives += in_recv
        total_in_delivers += in_deliv
        total_in_discards += in_disc
        total_in_hdr_errors += hdr_err
        total_in_addr_errors += addr_err
        total_in_no_routes += no_route
        total_icmp6_in_csum_errors += csum_err
        total_icmp6_in_errors += icmp6_err

        # Check header errors
        if in_recv > 50 and (hdr_err / in_recv) > WARN_MAX_HDR_ERROR_RATIO:
            ratio_pct = round((hdr_err / in_recv) * 100.0, 2)
            issues.append(f"Interface {iface} elevated IPv6 header errors: {hdr_err} ({ratio_pct}%)")
            recommendations.append(f"Inspect physical link/MTU corruption on {iface}")

        # Check address errors
        if in_recv > 50 and (addr_err / in_recv) > WARN_MAX_ADDR_ERROR_RATIO:
            ratio_pct = round((addr_err / in_recv) * 100.0, 2)
            issues.append(f"Interface {iface} elevated IPv6 address errors: {addr_err} ({ratio_pct}%)")

        # Check reassembly failures
        if reasm_reqds > 20 and (reasm_fails / reasm_reqds) > WARN_MAX_REASM_FAIL_RATIO:
            fail_pct = round((reasm_fails / reasm_reqds) * 100.0, 2)
            issues.append(f"Interface {iface} elevated IPv6 reassembly failures: {reasm_fails}/{reasm_reqds} ({fail_pct}%)")
            recommendations.append(f"Check IPv6 fragment buffer headroom or PMTU on {iface}")

        # Check ICMPv6 checksum errors
        if csum_err > 0:
            issues.append(f"Interface {iface} detected {csum_err} corrupted ICMPv6 checksum packets")

        # Check excessive discards on active interfaces delivering traffic
        if in_deliv > 100 and in_recv > 0 and (in_disc / in_recv) > WARN_MAX_DISCARD_RATIO:
            disc_pct = round((in_disc / in_recv) * 100.0, 2)
            issues.append(f"Interface {iface} high ingress discard ratio: {in_disc}/{in_recv} ({disc_pct}%)")

        interface_summaries[iface] = {
            "in_receives": in_recv,
            "in_delivers": in_deliv,
            "in_discards": in_disc,
            "in_hdr_errors": hdr_err,
            "in_no_routes": no_route,
            "icmp6_in_errors": icmp6_err,
            "icmp6_in_csum_errors": csum_err,
        }

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    summary: Dict[str, Any] = {
        "status": status,
        "healthy": healthy,
        "total_interfaces": total_interfaces,
        "total_in_receives": total_in_receives,
        "total_in_delivers": total_in_delivers,
        "total_in_discards": total_in_discards,
        "total_in_hdr_errors": total_in_hdr_errors,
        "total_in_addr_errors": total_in_addr_errors,
        "total_in_no_routes": total_in_no_routes,
        "total_icmp6_in_csum_errors": total_icmp6_in_csum_errors,
        "total_icmp6_in_errors": total_icmp6_in_errors,
        "issues": issues,
    }

    details: Dict[str, Any] = {
        "interfaces": interface_summaries,
        "recommendations": recommendations,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "details": details,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network Device Per-Interface IPv6 SNMP Diagnostics Guard (Pattern 243)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    parser.add_argument("--base-path", default=DEFAULT_DEV_SNMP6_PATH, help="Path to /proc/net/dev_snmp6")
    parser.add_argument("--verbose", action="store_true", help="Print verbose metric details")
    args = parser.parse_args()

    report = audit_dev_snmp6(base_path=args.base_path)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        summary = report["summary"]
        print(f"[{summary['status']}] Jev Host Per-Interface IPv6 SNMP Guard (Pattern 243)")
        print(f"  Interfaces scanned  : {summary['total_interfaces']}")
        print(f"  Total InReceives    : {summary['total_in_receives']}")
        print(f"  Total InDelivers    : {summary['total_in_delivers']}")
        print(f"  Total InDiscards    : {summary['total_in_discards']}")
        print(f"  Total InHdrErrors   : {summary['total_in_hdr_errors']}")
        print(f"  Total InAddrErrors  : {summary['total_in_addr_errors']}")
        print(f"  Total InNoRoutes    : {summary['total_in_no_routes']}")
        print(f"  ICMPv6 Csum Errors  : {summary['total_icmp6_in_csum_errors']}")
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
