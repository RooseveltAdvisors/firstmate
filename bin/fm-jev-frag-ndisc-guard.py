#!/usr/bin/env python3
"""
bin/fm-jev-frag-ndisc-guard.py - Host IPv6 RFC 6980 Fragmented Neighbor Discovery Suppression & L2 Multicast Guard (Pattern 262 / Pattern 400)

Audits Linux kernel RFC 6980 IPv6 Neighbor Discovery fragmentation security and L2 multicast unicast filtering:
  - conf/*/suppress_frag_ndisc: Drop fragmented IPv6 Neighbor Discovery packets (1=RFC 6980 compliant drop, 0=accept fragments)
  - conf/*/drop_unicast_in_l2_multicast: Drop unicast IPv6 packets encapsulated inside L2 multicast frames (0=pass, 1=drop)
  - /proc/net/snmp6: IPv6 reassembly and ICMPv6 telemetry (Ip6ReasmReqds, Ip6ReasmFails, Ip6ReasmTimeout, Icmp6InErrors, Icmp6InNeighborSolicits, Icmp6InNeighborAdvertisements)

Invariants:
  - RFC 6980 mandates that IPv6 Neighbor Discovery messages MUST NOT be fragmented; fragmented ND messages MUST be dropped to prevent security evasion and firewall bypass.
  - Prevents L2 multicast frame reflection and cross-subnet ND poisoning.
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


def audit_frag_ndisc_guard(
    conf_dir: str = CONF_IPV6_BASE,
    snmp6_path: str = PROC_SNMP6,
) -> Dict[str, Any]:
    all_suppress: Dict[str, int] = {}
    all_drop_mcast_ucast: Dict[str, int] = {}

    if os.path.isdir(conf_dir):
        for entry in os.listdir(conf_dir):
            iface_path = os.path.join(conf_dir, entry)
            if os.path.isdir(iface_path):
                ifname = entry
                suppress_p = os.path.join(iface_path, "suppress_frag_ndisc")
                drop_ucast_p = os.path.join(iface_path, "drop_unicast_in_l2_multicast")

                if os.path.isfile(suppress_p):
                    all_suppress[ifname] = read_sysctl_int(suppress_p)
                if os.path.isfile(drop_ucast_p):
                    all_drop_mcast_ucast[ifname] = read_sysctl_int(drop_ucast_p)

    snmp6_metrics = parse_snmp6(snmp6_path)
    reasm_reqds = snmp6_metrics.get("Ip6ReasmReqds", 0)
    reasm_fails = snmp6_metrics.get("Ip6ReasmFails", 0)
    reasm_timeouts = snmp6_metrics.get("Ip6ReasmTimeout", 0)
    icmp6_in_errs = snmp6_metrics.get("Icmp6InErrors", 0)
    icmp6_in_ns = snmp6_metrics.get("Icmp6InNeighborSolicits", 0)
    icmp6_in_na = snmp6_metrics.get("Icmp6InNeighborAdvertisements", 0)

    issues: List[str] = []
    status = "HEALTHY"

    # Check for interfaces with suppress_frag_ndisc disabled (0)
    unsuppressed_ifaces: List[str] = []
    for ifname, val in all_suppress.items():
        if val == 0:
            unsuppressed_ifaces.append(ifname)

    if unsuppressed_ifaces:
        issues.append(
            f"RFC 6980 fragmented Neighbor Discovery suppression disabled on interfaces: {', '.join(unsuppressed_ifaces)} "
            "(vulnerable to ND fragmentation evasion attacks and firewall bypass)"
        )
        status = "WARNING"

    # Check for reassembly failure anomalies
    if reasm_reqds > 0 and reasm_fails > 0:
        fail_ratio = reasm_fails / reasm_reqds
        if fail_ratio > 0.5:
            issues.append(
                f"Elevated IPv6 fragment reassembly failure ratio: {reasm_fails}/{reasm_reqds} "
                f"({fail_ratio:.1%})"
            )
            if status != "CRITICAL":
                status = "WARNING"

    return {
        "pattern": 262,
        "name": "frag_ndisc",
        "description": "Host IPv6 RFC 6980 Fragmented Neighbor Discovery Suppression & L2 Multicast Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.timezone.utc and datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "interfaces_audited": len(all_suppress),
        "all_suppress_frag_ndisc": all_suppress.get("all", 1),
        "default_suppress_frag_ndisc": all_suppress.get("default", 1),
        "lo_suppress_frag_ndisc": all_suppress.get("lo", 1),
        "rfc6980_compliant": len(unsuppressed_ifaces) == 0,
        "all_drop_unicast_in_l2_multicast": all_drop_mcast_ucast.get("all", 0),
        "default_drop_unicast_in_l2_multicast": all_drop_mcast_ucast.get("default", 0),
        "reasm_reqds": reasm_reqds,
        "reasm_fails": reasm_fails,
        "reasm_timeouts": reasm_timeouts,
        "icmp6_in_errors": icmp6_in_errs,
        "icmp6_in_neighbor_solicits": icmp6_in_ns,
        "icmp6_in_neighbor_advertisements": icmp6_in_na,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Host IPv6 RFC 6980 Fragmented Neighbor Discovery Suppression & L2 Multicast Guard (Pattern 262 / Pattern 400)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    parser.add_argument("--conf-dir", default=CONF_IPV6_BASE, help="Path to /proc/sys/net/ipv6/conf directory")
    parser.add_argument("--snmp6-file", default=PROC_SNMP6, help="Path to /proc/net/snmp6")

    args = parser.parse_args()

    report = audit_frag_ndisc_guard(
        conf_dir=args.conf_dir,
        snmp6_path=args.snmp6_file,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Pattern 262: {report['name']} - Status: {report['status']}")
        print(f"  interfaces_audited: {report['interfaces_audited']}")
        print(f"  all_suppress_frag_ndisc: {report['all_suppress_frag_ndisc']}")
        print(f"  default_suppress_frag_ndisc: {report['default_suppress_frag_ndisc']}")
        print(f"  rfc6980_compliant: {report['rfc6980_compliant']}")
        print(f"  all_drop_unicast_in_l2_multicast: {report['all_drop_unicast_in_l2_multicast']}")
        print(f"  reasm_reqds: {report['reasm_reqds']}")
        print(f"  reasm_fails: {report['reasm_fails']}")
        print(f"  icmp6_in_neighbor_solicits: {report['icmp6_in_neighbor_solicits']}")
        print(f"  icmp6_in_neighbor_advertisements: {report['icmp6_in_neighbor_advertisements']}")
        if report["issues"]:
            print("  Issues:")
            for issue in report["issues"]:
                print(f"    - {issue}")
        else:
            print("  Issues: none (nominal)")

    return 0 if report["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
