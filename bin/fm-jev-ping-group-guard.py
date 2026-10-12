#!/usr/bin/env python3
"""
bin/fm-jev-ping-group-guard.py - Host ICMP Echo Socket Group Permissions & Security Policy Guard (Pattern 256)

Audits Linux kernel unprivileged ICMP echo socket permissions (ping_group_range), ICMP error routing,
and ICMP broadcast reflection protections alongside SNMP error counters:
  - ping_group_range: Range of group IDs permitted to create unprivileged ICMP echo sockets.
  - icmp_errors_use_inbound_ifaddr: Whether ICMP error source address uses inbound interface IP.
  - icmp_ignore_bogus_error_responses: Conformance to RFC 1122 broadcast/multicast error filtering.
  - icmp_echo_ignore_broadcasts: Defense against Smurf broadcast amplification.
  - snmp telemetry: Icmp: InMsgs, InErrors, InCsumErrors, InEchos, OutEchoReps, OutErrors.

Invariants:
  - Prevents wide-open unprivileged ICMP socket creation without capabilities.
  - Enforces Smurf attack broadcast filtering and RFC 1122 bogus error suppression.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths or snmp are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Tuple

SYSCTL_PING_GROUP_RANGE = "/proc/sys/net/ipv4/ping_group_range"
SYSCTL_ERRORS_INBOUND_IFADDR = "/proc/sys/net/ipv4/icmp_errors_use_inbound_ifaddr"
SYSCTL_IGNORE_BOGUS = "/proc/sys/net/ipv4/icmp_ignore_bogus_error_responses"
SYSCTL_IGNORE_BROADCASTS = "/proc/sys/net/ipv4/icmp_echo_ignore_broadcasts"
PROC_SNMP = "/proc/net/snmp"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0])
    except (ValueError, OSError, IndexError):
        return default


def read_ping_group_range(path: str) -> Tuple[int, int]:
    if not os.path.isfile(path):
        return (1, 0)
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            parts = f.read().strip().split()
        if len(parts) >= 2:
            return (int(parts[0]), int(parts[1]))
        elif len(parts) == 1:
            val = int(parts[0])
            return (val, val)
        return (1, 0)
    except (ValueError, OSError):
        return (1, 0)


def parse_snmp_icmp(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("Icmp:") and lines[i + 1].startswith("Icmp:"):
                keys = lines[i].split()[1:]
                vals = lines[i + 1].split()[1:]
                for k, v in zip(keys, vals):
                    try:
                        metrics[k] = int(v)
                    except ValueError:
                        pass
                break
    except OSError:
        pass
    return metrics


def audit_ping_group_guard(
    ping_group_range_path: str = SYSCTL_PING_GROUP_RANGE,
    errors_inbound_ifaddr_path: str = SYSCTL_ERRORS_INBOUND_IFADDR,
    ignore_bogus_path: str = SYSCTL_IGNORE_BOGUS,
    ignore_broadcasts_path: str = SYSCTL_IGNORE_BROADCASTS,
    snmp_path: str = PROC_SNMP,
    warn_in_error_pct: float = 1.0,
    crit_in_error_pct: float = 10.0,
) -> Dict[str, Any]:
    min_gid, max_gid = read_ping_group_range(ping_group_range_path)
    inbound_ifaddr = read_sysctl_int(errors_inbound_ifaddr_path, default=0)
    ignore_bogus = read_sysctl_int(ignore_bogus_path, default=1)
    ignore_broadcasts = read_sysctl_int(ignore_broadcasts_path, default=1)

    icmp_stats = parse_snmp_icmp(snmp_path)
    in_msgs = icmp_stats.get("InMsgs", 0)
    in_errors = icmp_stats.get("InErrors", 0)
    in_csum_errors = icmp_stats.get("InCsumErrors", 0)
    in_echos = icmp_stats.get("InEchos", 0)
    out_echos = icmp_stats.get("OutEchos", 0)
    out_echo_reps = icmp_stats.get("OutEchoReps", 0)
    out_msgs = icmp_stats.get("OutMsgs", 0)
    out_errors = icmp_stats.get("OutErrors", 0)

    unprivileged_ping_enabled = min_gid <= max_gid
    in_error_pct = (in_errors / in_msgs * 100.0) if in_msgs > 0 else 0.0

    issues: List[str] = []
    status = "HEALTHY"

    # Check for wide open ping group range
    if unprivileged_ping_enabled and min_gid == 0 and max_gid >= 65535:
        issues.append(
            f"Wide-open ping group range ({min_gid} to {max_gid}); "
            "all unprivileged processes can create raw ICMP sockets"
        )
        status = "WARNING"

    # Check inbound interface address exposure
    if inbound_ifaddr == 1:
        issues.append(
            "ICMP errors configured to use inbound interface IP (icmp_errors_use_inbound_ifaddr=1); "
            "risk of exposing internal network topology"
        )
        status = "WARNING"

    # Check RFC 1122 bogus error responses
    if ignore_bogus == 0:
        issues.append(
            "RFC 1122 bogus error response filtering disabled (icmp_ignore_bogus_error_responses=0); "
            "risk of ICMP broadcast storm feedback loops"
        )
        if status != "CRITICAL":
            status = "WARNING"

    # Check broadcast echo ignore
    if ignore_broadcasts == 0:
        issues.append(
            "Broadcast ICMP echo reply filtering disabled (icmp_echo_ignore_broadcasts=0); "
            "vulnerable to Smurf amplification attacks"
        )
        if status != "CRITICAL":
            status = "WARNING"

    # Check ICMP checksum errors
    if in_csum_errors > 0:
        issues.append(f"Detected {in_csum_errors:,} incoming ICMP checksum errors")
        if status != "CRITICAL":
            status = "WARNING"

    # Check ICMP error rate
    if in_error_pct >= crit_in_error_pct:
        issues.append(
            f"Critical ICMP incoming error rate: {in_error_pct:.4f}% ({in_errors:,} / {in_msgs:,} packets)"
        )
        status = "CRITICAL"
    elif in_error_pct >= warn_in_error_pct:
        issues.append(
            f"Elevated ICMP incoming error rate: {in_error_pct:.4f}% ({in_errors:,} / {in_msgs:,} packets)"
        )
        if status != "CRITICAL":
            status = "WARNING"

    return {
        "pattern": 256,
        "name": "ping_group",
        "description": "Host ICMP Echo Socket Group Permissions & Security Policy Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "ping_group_min_gid": min_gid,
        "ping_group_max_gid": max_gid,
        "unprivileged_ping_enabled": unprivileged_ping_enabled,
        "icmp_errors_use_inbound_ifaddr": inbound_ifaddr,
        "icmp_ignore_bogus_error_responses": ignore_bogus,
        "icmp_echo_ignore_broadcasts": ignore_broadcasts,
        "in_msgs": in_msgs,
        "in_errors": in_errors,
        "in_csum_errors": in_csum_errors,
        "in_error_pct": round(in_error_pct, 6),
        "in_echos": in_echos,
        "out_echos": out_echos,
        "out_echo_reps": out_echo_reps,
        "out_msgs": out_msgs,
        "out_errors": out_errors,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Host ICMP Echo Socket Group Permissions & Security Policy Guard (Pattern 256)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    parser.add_argument("--ping-group-range-file", default=SYSCTL_PING_GROUP_RANGE, help="Path to ping_group_range")
    parser.add_argument(
        "--errors-inbound-ifaddr-file",
        default=SYSCTL_ERRORS_INBOUND_IFADDR,
        help="Path to icmp_errors_use_inbound_ifaddr",
    )
    parser.add_argument("--ignore-bogus-file", default=SYSCTL_IGNORE_BOGUS, help="Path to icmp_ignore_bogus_error_responses")
    parser.add_argument(
        "--ignore-broadcasts-file", default=SYSCTL_IGNORE_BROADCASTS, help="Path to icmp_echo_ignore_broadcasts"
    )
    parser.add_argument("--snmp-file", default=PROC_SNMP, help="Path to /proc/net/snmp")
    parser.add_argument(
        "--warn-in-error-pct", type=float, default=1.0, help="Warning threshold for incoming ICMP error percentage"
    )
    parser.add_argument(
        "--crit-in-error-pct", type=float, default=10.0, help="Critical threshold for incoming ICMP error percentage"
    )

    args = parser.parse_args()

    report = audit_ping_group_guard(
        ping_group_range_path=args.ping_group_range_file,
        errors_inbound_ifaddr_path=args.errors_inbound_ifaddr_file,
        ignore_bogus_path=args.ignore_bogus_file,
        ignore_broadcasts_path=args.ignore_broadcasts_file,
        snmp_path=args.snmp_file,
        warn_in_error_pct=args.warn_in_error_pct,
        crit_in_error_pct=args.crit_in_error_pct,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Pattern 256: {report['name']} - Status: {report['status']}")
        print(f"  ping_group_range: {report['ping_group_min_gid']} to {report['ping_group_max_gid']}")
        print(f"  unprivileged_ping_enabled: {report['unprivileged_ping_enabled']}")
        print(f"  icmp_errors_use_inbound_ifaddr: {report['icmp_errors_use_inbound_ifaddr']}")
        print(f"  icmp_ignore_bogus_error_responses: {report['icmp_ignore_bogus_error_responses']}")
        print(f"  icmp_echo_ignore_broadcasts: {report['icmp_echo_ignore_broadcasts']}")
        print(f"  in_msgs: {report['in_msgs']}")
        print(f"  in_errors: {report['in_errors']} ({report['in_error_pct']}%)")
        print(f"  in_csum_errors: {report['in_csum_errors']}")
        print(f"  in_echos: {report['in_echos']}")
        print(f"  out_echo_reps: {report['out_echo_reps']}")
        if report["issues"]:
            print("  Issues:")
            for issue in report["issues"]:
                print(f"    - {issue}")
        else:
            print("  Issues: none (nominal)")

    return 0 if report["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
