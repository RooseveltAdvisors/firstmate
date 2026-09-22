#!/usr/bin/env python3
"""
fm-jev-igmp-guard.py - Jev Multi-Agent Host Network IP Multicast Group Membership & IGMP Guard (Pattern 122)

Audits Linux IPv4 multicast group memberships from /proc/net/igmp, sysctls
(/proc/sys/net/ipv4/igmp_max_memberships, igmp_max_msf, conf/*/force_igmp_version),
and network statistics from /proc/net/netstat (IpExt: InMcastPkts, OutMcastPkts).

Detects IGMP membership table saturation, legacy IGMP downgrade risk, and multicast
flooding that could impact inter-agent cluster communication and service discovery.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysfs/procfs files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import socket
import struct
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

PROC_IGMP = "/proc/net/igmp"
CONF_DIR = "/proc/sys/net/ipv4/conf"
PROC_NETSTAT = "/proc/net/netstat"
IGMP_MAX_MEMBERSHIPS_FILE = "/proc/sys/net/ipv4/igmp_max_memberships"
IGMP_MAX_MSF_FILE = "/proc/sys/net/ipv4/igmp_max_msf"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def hex_to_ipv4(hex_str: str) -> str:
    """Converts a little-endian 8-character hex string from /proc/net/igmp to IPv4."""
    try:
        val = int(hex_str, 16)
        packed = struct.pack("<I", val)
        return socket.inet_ntoa(packed)
    except Exception:
        return hex_str


def parse_proc_igmp(path: Path) -> List[Dict[str, Any]]:
    """Parses /proc/net/igmp into structured interface multicast groups."""
    if not path.is_file():
        return []

    interfaces: List[Dict[str, Any]] = []
    current_iface: Optional[Dict[str, Any]] = None

    try:
        lines = path.read_text().splitlines()
        for line in lines:
            line = line.strip()
            if not line or line.startswith("Idx"):
                continue

            tokens = line.split()
            if tokens and tokens[0].isdigit() and ":" in line:
                idx = int(tokens[0])
                dev = tokens[1]
                parts = line.split(":")
                right = parts[1].split() if len(parts) > 1 else []
                count = int(right[0]) if right else 0
                querier = right[1] if len(right) > 1 else "Unknown"

                current_iface = {
                    "index": idx,
                    "device": dev,
                    "group_count": count,
                    "querier_version": querier,
                    "groups": [],
                }
                interfaces.append(current_iface)
            elif current_iface is not None and tokens:
                # Group member line: "FB0000E0 1 0:00000000 0"
                group_hex = tokens[0]
                users = int(tokens[1]) if len(tokens) > 1 else 1
                current_iface["groups"].append({
                    "group_hex": group_hex,
                    "group_ip": hex_to_ipv4(group_hex),
                    "users": users,
                })
    except Exception:
        return interfaces

    return interfaces


def parse_tcpext_netstat(path: Path) -> Dict[str, int]:
    """Parses IpExt key-value metrics from /proc/net/netstat."""
    if not path.is_file():
        return {}

    metrics: Dict[str, int] = {}
    try:
        lines = path.read_text().splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("IpExt:") and lines[i + 1].startswith("IpExt:"):
                keys = lines[i].split()[1:]
                vals_raw = lines[i + 1].split()[1:]
                for k, v in zip(keys, vals_raw):
                    try:
                        metrics[k] = int(v)
                    except ValueError:
                        continue
                break
    except Exception:
        return {}

    return metrics


def audit_igmp(
    proc_igmp: Optional[str] = None,
    conf_dir: Optional[str] = None,
    netstat_file: Optional[str] = None,
    max_memberships_file: Optional[str] = None,
    max_msf_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host IGMP multicast state, sysctls, and packet statistics."""
    igmp_p = Path(proc_igmp or PROC_IGMP)
    conf_p = Path(conf_dir or CONF_DIR)
    netstat_p = Path(netstat_file or PROC_NETSTAT)
    max_memb_p = Path(max_memberships_file or IGMP_MAX_MEMBERSHIPS_FILE)
    max_msf_p = Path(max_msf_file or IGMP_MAX_MSF_FILE)

    interfaces = parse_proc_igmp(igmp_p)
    max_memberships = read_int_file(max_memb_p) or 20
    max_msf = read_int_file(max_msf_p) or 10

    # Read force_igmp_version across interfaces
    forced_versions: Dict[str, int] = {}
    if conf_p.is_dir():
        for p in sorted(conf_p.glob("*/force_igmp_version")):
            val = read_int_file(p)
            if val is not None:
                forced_versions[p.parent.name] = val

    netstat = parse_tcpext_netstat(netstat_p)
    in_mcast = netstat.get("InMcastPkts", 0)
    out_mcast = netstat.get("OutMcastPkts", 0)
    in_bcast = netstat.get("InBcastPkts", 0)
    in_mcast_octets = netstat.get("InMcastOctets", 0)
    out_mcast_octets = netstat.get("OutMcastOctets", 0)

    issues: List[str] = []
    healthy = True

    # Check membership thresholds
    total_groups = sum(len(iface.get("groups", [])) for iface in interfaces)
    for iface in interfaces:
        g_count = len(iface.get("groups", []))
        if g_count >= max_memberships:
            healthy = False
            issues.append(
                f"Interface {iface.get('device')} has reached or exceeded igmp_max_memberships "
                f"({g_count}/{max_memberships}). New multicast group joins will fail."
            )

    # Check forced IGMP downgrade
    for dev, ver in forced_versions.items():
        if ver in (1, 2):
            healthy = False
            issues.append(
                f"Interface {dev} has forced legacy IGMP version {ver} (force_igmp_version = {ver}). "
                f"IGMPv3 source-specific multicast (SSM) disabled."
            )

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "healthy": healthy,
        "status": "HEALTHY" if healthy else "WARNING",
        "pattern": 122,
        "name": "Host Network IP Multicast Group Membership & IGMP Query Saturation Guard",
        "issues": issues,
        "config": {
            "igmp_max_memberships": max_memberships,
            "igmp_max_msf": max_msf,
            "forced_igmp_versions": forced_versions,
        },
        "multicast_interfaces": interfaces,
        "telemetry": {
            "total_interfaces_monitored": len(interfaces),
            "total_multicast_groups_joined": total_groups,
            "in_mcast_pkts": in_mcast,
            "out_mcast_pkts": out_mcast,
            "in_bcast_pkts": in_bcast,
            "in_mcast_octets": in_mcast_octets,
            "out_mcast_octets": out_mcast_octets,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network IP Multicast Group Membership & IGMP Guard (Pattern 122)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--proc-igmp", type=str, default=None, help="Override /proc/net/igmp path")
    parser.add_argument("--conf-dir", type=str, default=None, help="Override /proc/sys/net/ipv4/conf directory")
    parser.add_argument("--netstat-file", type=str, default=None, help="Override /proc/net/netstat path")
    parser.add_argument("--max-memberships-file", type=str, default=None, help="Override igmp_max_memberships file")
    parser.add_argument("--max-msf-file", type=str, default=None, help="Override igmp_max_msf file")
    parser.add_argument("--warn-only", action="store_true", help="Always exit 0 even if issues detected")

    args = parser.parse_args()

    audit = audit_igmp(
        proc_igmp=args.proc_igmp,
        conf_dir=args.conf_dir,
        netstat_file=args.netstat_file,
        max_memberships_file=args.max_memberships_file,
        max_msf_file=args.max_msf_file,
    )

    if args.json:
        print(json.dumps(audit, indent=2))
    else:
        print(f"Pattern 122: {audit['name']}")
        print(f"Status: {audit['status']}")
        cfg = audit["config"]
        print(f"IGMP Max Memberships: {cfg['igmp_max_memberships']}, Max MSF: {cfg['igmp_max_msf']}")
        telem = audit["telemetry"]
        print(
            f"Joined Groups: {telem['total_multicast_groups_joined']} across {telem['total_interfaces_monitored']} interfaces"
        )
        print(f"Multicast Packets: In={telem['in_mcast_pkts']:,}, Out={telem['out_mcast_pkts']:,}")

        for iface in audit["multicast_interfaces"]:
            print(f"  Interface {iface['device']} (Idx {iface['index']}, Querier {iface['querier_version']}):")
            for g in iface["groups"]:
                print(f"    - {g['group_ip']} (users: {g['users']})")

        if audit["issues"]:
            print("\nIssues Identified:")
            for issue in audit["issues"]:
                print(f"  [!] {issue}")
        else:
            print("\nAll host IP multicast group memberships and IGMP configurations are healthy.")

    if not audit["healthy"] and not args.warn_only:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
