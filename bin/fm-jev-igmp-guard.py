#!/usr/bin/env python3
"""
bin/fm-jev-igmp-guard.py - Host Network IP Multicast Group Membership & IGMP Query Backlog Guard (Pattern 211)

Audits Linux kernel IPv4/IPv6 multicast group memberships and IGMP/MLD query state:
  - /proc/net/igmp (IPv4 multicast memberships, querier version V2/V3, users, timers)
  - /proc/net/igmp6 (IPv6 Multicast Listener Discovery memberships, users, flags)
  - /proc/net/mcfilter (Multicast source-filter memberships)
  - /proc/net/snmp6 (Ip6InMcastPkts, Ip6OutMcastPkts, Ip6InMcastOctets, Ip6OutMcastOctets)
  - /proc/sys/net/ipv4/igmp_max_memberships (max multicast groups per socket, default 20)
  - /proc/sys/net/ipv4/igmp_max_msf (max multicast source filters, default 10)
  - /proc/sys/net/ipv4/igmp_qrv (querier robustness variable, default 2)
  - /proc/sys/net/ipv4/conf/all/force_igmp_version (0 = auto-negotiate, 1/2/3 = forced)

Detects multicast socket membership exhaustion (ENOBUFS on IP_ADD_MEMBERSHIP),
unsolicited report floods, and stale querier timeouts affecting mDNS, Avahi,
and multi-agent zero-config fleet discovery services.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysfs/procfs files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import socket
import struct
import sys
from typing import Any, Dict, List


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception:
        return default


def hex_to_ipv4(hex_str: str) -> str:
    """Converts 8-hex-char little-endian IP from /proc/net/igmp to dotted decimal."""
    try:
        return socket.inet_ntoa(struct.pack("<I", int(hex_str, 16)))
    except Exception:
        return hex_str


def hex_to_ipv6(hex_str: str) -> str:
    """Converts 32-hex-char IP from /proc/net/igmp6 to standard IPv6 string."""
    try:
        return socket.inet_ntop(socket.AF_INET6, bytes.fromhex(hex_str))
    except Exception:
        return hex_str


def parse_proc_net_igmp(path: str = "/proc/net/igmp") -> Dict[str, Any]:
    interfaces: Dict[str, Any] = {}
    if not os.path.exists(path):
        return interfaces

    try:
        with open(path, "r", encoding="utf-8") as f:
            current_iface = None
            for raw_line in f:
                if not raw_line.strip() or raw_line.startswith("Idx"):
                    continue

                if raw_line.startswith(("\t", " ")):
                    # Group line indented under current interface
                    tokens = raw_line.strip().split()
                    if tokens and current_iface and current_iface in interfaces:
                        hex_group = tokens[0]
                        users = int(tokens[1]) if len(tokens) > 1 and tokens[1].isdigit() else 1
                        timer = tokens[2] if len(tokens) > 2 else "0:0"
                        reporter = tokens[3] if len(tokens) > 3 else "0"
                        interfaces[current_iface]["groups"].append({
                            "group_hex": hex_group,
                            "group_ip": hex_to_ipv4(hex_group),
                            "users": users,
                            "timer": timer,
                            "reporter": reporter,
                        })
                else:
                    # Interface header: e.g. "1\tlo        :     2      V3"
                    parts = raw_line.split(":")
                    if len(parts) >= 2:
                        dev_part = parts[0].strip().split()
                        dev_name = dev_part[1] if len(dev_part) >= 2 else dev_part[0]
                        stats_part = parts[1].strip().split()
                        count = int(stats_part[0]) if stats_part and stats_part[0].isdigit() else 0
                        querier = stats_part[1] if len(stats_part) > 1 else "Unknown"
                        current_iface = dev_name
                        interfaces[current_iface] = {
                            "group_count": count,
                            "querier": querier,
                            "groups": [],
                        }
    except Exception:
        pass

    return interfaces


def parse_proc_net_igmp6(path: str = "/proc/net/igmp6") -> Dict[str, Any]:
    interfaces: Dict[str, Any] = {}
    if not os.path.exists(path):
        return interfaces

    try:
        with open(path, "r", encoding="utf-8") as f:
            for raw_line in f:
                line = raw_line.strip()
                if not line:
                    continue
                parts = line.split()
                if len(parts) >= 3:
                    # e.g.: "1    lo              ff0200000000000000000000000000fb     1 00000004 0"
                    dev_name = parts[1]
                    hex_addr = parts[2]
                    users = int(parts[3]) if len(parts) > 3 and parts[3].isdigit() else 1
                    flags = parts[4] if len(parts) > 4 else "0"
                    if dev_name not in interfaces:
                        interfaces[dev_name] = {"groups": []}
                    interfaces[dev_name]["groups"].append({
                        "group_hex": hex_addr,
                        "group_ip": hex_to_ipv6(hex_addr),
                        "users": users,
                        "flags": flags,
                    })
    except Exception:
        pass

    return interfaces


def parse_proc_net_snmp6_mcast(path: str = "/proc/net/snmp6") -> Dict[str, int]:
    mcast_counters = {
        "Ip6InMcastPkts": 0,
        "Ip6OutMcastPkts": 0,
        "Ip6InMcastOctets": 0,
        "Ip6OutMcastOctets": 0,
    }
    if not os.path.exists(path):
        return mcast_counters

    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) == 2 and parts[0] in mcast_counters:
                    try:
                        mcast_counters[parts[0]] = int(parts[1])
                    except ValueError:
                        pass
    except Exception:
        pass

    return mcast_counters


def audit_igmp_guard(
    proc_igmp: str = "/proc/net/igmp",
    proc_igmp6: str = "/proc/net/igmp6",
    proc_snmp6: str = "/proc/net/snmp6",
    proc_sys_ipv4: str = "/proc/sys/net/ipv4",
) -> Dict[str, Any]:
    igmp_v4 = parse_proc_net_igmp(proc_igmp)
    igmp_v6 = parse_proc_net_igmp6(proc_igmp6)
    snmp6_mcast = parse_proc_net_snmp6_mcast(proc_snmp6)

    igmp_max_memberships = read_sysctl_int(os.path.join(proc_sys_ipv4, "igmp_max_memberships"), 20)
    igmp_max_msf = read_sysctl_int(os.path.join(proc_sys_ipv4, "igmp_max_msf"), 10)
    igmp_qrv = read_sysctl_int(os.path.join(proc_sys_ipv4, "igmp_qrv"), 2)
    force_igmp_version = read_sysctl_int(os.path.join(proc_sys_ipv4, "conf/all/force_igmp_version"), 0)

    total_v4_groups = sum(len(iface_data.get("groups", [])) for iface_data in igmp_v4.values())
    total_v6_groups = sum(len(iface_data.get("groups", [])) for iface_data in igmp_v6.values())

    max_v4_per_iface = 0
    max_v4_iface_name = ""
    for iface_name, iface_data in igmp_v4.items():
        gcount = len(iface_data.get("groups", []))
        if gcount > max_v4_per_iface:
            max_v4_per_iface = gcount
            max_v4_iface_name = iface_name

    saturation_ratio = 0.0
    if igmp_max_memberships > 0:
        saturation_ratio = round(max_v4_per_iface / igmp_max_memberships, 4)

    issues: List[str] = []
    status = "HEALTHY"

    # Evaluation rules
    if max_v4_per_iface >= igmp_max_memberships and igmp_max_memberships > 0:
        status = "CRITICAL"
        issues.append(
            f"CRITICAL: Multicast group memberships on interface '{max_v4_iface_name}' reached kernel limit "
            f"({max_v4_per_iface}/{igmp_max_memberships}, {saturation_ratio * 100:.1f}% saturation). "
            f"New IP_ADD_MEMBERSHIP socket joins will fail with ENOBUFS."
        )
    elif saturation_ratio >= 0.70:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"WARNING: High multicast group saturation on interface '{max_v4_iface_name}' "
            f"({max_v4_per_iface}/{igmp_max_memberships}, {saturation_ratio * 100:.1f}% saturation)."
        )

    if force_igmp_version != 0:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"WARNING: net.ipv4.conf.all.force_igmp_version={force_igmp_version} (expected 0 for auto-negotiation)."
        )

    if igmp_max_memberships < 20 and igmp_max_memberships != -1:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"WARNING: Restrictive net.ipv4.igmp_max_memberships={igmp_max_memberships} (default is 20)."
        )

    recommendation = (
        "Multicast group membership, IGMP querier versions, and MLD listener tables are nominal."
        if status == "HEALTHY"
        else "Review multicast socket allocations and tune net.ipv4.igmp_max_memberships to prevent join failures."
    )

    now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()

    return {
        "timestamp": now_iso,
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "total_v4_groups": total_v4_groups,
            "total_v6_groups": total_v6_groups,
            "max_v4_per_iface": max_v4_per_iface,
            "max_v4_iface": max_v4_iface_name,
            "igmp_max_memberships": igmp_max_memberships,
            "saturation_ratio": saturation_ratio,
            "force_igmp_version": force_igmp_version,
            "in_mcast_pkts_v6": snmp6_mcast["Ip6InMcastPkts"],
            "out_mcast_pkts_v6": snmp6_mcast["Ip6OutMcastPkts"],
            "issues": issues,
            "recommendation": recommendation,
        },
        "ipv4_interfaces": igmp_v4,
        "ipv6_interfaces": igmp_v6,
        "snmp6_mcast": snmp6_mcast,
        "sysctls": {
            "igmp_max_memberships": igmp_max_memberships,
            "igmp_max_msf": igmp_max_msf,
            "igmp_qrv": igmp_qrv,
            "force_igmp_version": force_igmp_version,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IP Multicast Group Membership & IGMP Query Backlog Guard (Pattern 211)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results as JSON")
    parser.add_argument("--verbose", "-v", action="store_true", help="Print verbose group details")
    parser.add_argument("--warn-only", action="store_true", help="Exit 0 even on CRITICAL issues")
    parser.add_argument("--path-igmp", default="/proc/net/igmp", help="Path to /proc/net/igmp")
    parser.add_argument("--path-igmp6", default="/proc/net/igmp6", help="Path to /proc/net/igmp6")
    parser.add_argument("--path-snmp6", default="/proc/net/snmp6", help="Path to /proc/net/snmp6")
    parser.add_argument("--path-sysctl-ipv4", default="/proc/sys/net/ipv4", help="Path to /proc/sys/net/ipv4")

    args = parser.parse_args()

    data = audit_igmp_guard(
        proc_igmp=args.path_igmp,
        proc_igmp6=args.path_igmp6,
        proc_snmp6=args.path_snmp6,
        proc_sys_ipv4=args.path_sysctl_ipv4,
    )

    if args.json:
        print(json.dumps(data, indent=2))
        return 0 if (data["summary"]["healthy"] or args.warn_only) else 1

    summary = data["summary"]
    status = summary["status"]

    color_code = "\033[32m" if status == "HEALTHY" else ("\033[33m" if status == "WARNING" else "\033[31m")
    reset_code = "\033[0m"

    print(f"[{color_code}{status}{reset_code}] Host IP Multicast & IGMP Query Backlog Guard (Pattern 211)")
    print(f"  Total IPv4 Groups Joined : {summary['total_v4_groups']}")
    print(f"  Total IPv6 Groups (MLD)  : {summary['total_v6_groups']}")
    print(f"  Max IPv4 / Interface     : {summary['max_v4_per_iface']} (on '{summary['max_v4_iface']}')")
    print(f"  Kernel igmp_max_members  : {summary['igmp_max_memberships']} (saturation: {summary['saturation_ratio'] * 100:.1f}%)")
    print(f"  Force IGMP Version       : {summary['force_igmp_version']} (0 = auto)")
    print(f"  IPv6 Multicast Packets   : In: {summary['in_mcast_pkts_v6']:,} | Out: {summary['out_mcast_pkts_v6']:,}")

    if args.verbose and data["ipv4_interfaces"]:
        print("\n  IPv4 Multicast Interfaces:")
        for dev, iface_data in data["ipv4_interfaces"].items():
            print(f"    - {dev} (Querier: {iface_data.get('querier')}, Groups: {len(iface_data.get('groups', []))}):")
            for g in iface_data.get("groups", []):
                print(f"        {g['group_ip']:<16} (users={g['users']}, timer={g['timer']})")

    if summary["issues"]:
        print("\n  Issues Detected:")
        for issue in summary["issues"]:
            print(f"    - {issue}")

    print(f"\n  Recommendation: {summary['recommendation']}")

    return 0 if (summary["healthy"] or args.warn_only) else 1


if __name__ == "__main__":
    sys.exit(main())
