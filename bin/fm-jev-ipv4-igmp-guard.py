#!/usr/bin/env python3
"""
bin/fm-jev-ipv4-igmp-guard.py - Linux IPv4 Internet Group Management Protocol (IGMP) & Multicast Policy Guard (Pattern 296 / Pattern 434)

Audits Linux kernel IPv4 IGMP parameters and multicast telemetry:
  - /proc/sys/net/ipv4/conf/*/force_igmp_version: 0=auto (RFC 3376 v3), 1=force IGMPv1, 2=force IGMPv2
  - /proc/sys/net/ipv4/conf/*/igmpv2_unsolicited_report_interval: IGMPv2 unsolicited report interval in ms (default 10000ms)
  - /proc/sys/net/ipv4/conf/*/igmpv3_unsolicited_report_interval: IGMPv3 unsolicited report interval in ms (default 1000ms)
  - /proc/sys/net/ipv4/igmp_max_memberships: Maximum multicast group memberships per socket (default 20)
  - /proc/sys/net/ipv4/igmp_max_msf: Maximum multicast source filters (default 10)
  - /proc/sys/net/ipv4/igmp_qrv: Querier Robustness Variable (RFC 3376 §8.1, default 2)
  - /proc/net/igmp: Active IPv4 multicast group memberships
  - /proc/net/netstat: Multicast packet metrics (InMcastPkts, OutMcastPkts, InBcastPkts, OutBcastPkts)

Invariants:
  - QRV (Querier Robustness Variable) must be between 1 and 7 (RFC 3376 §8.1).
  - Unsolicited report intervals must maintain sufficient backoff (floor >= 100ms) to prevent report storms.
  - Fail-open: graceful fallback when sysctl paths or /proc/net are restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

CONF_IPV4_BASE = "/proc/sys/net/ipv4/conf"
PROC_SYS_IPV4_BASE = "/proc/sys/net/ipv4"
PROC_IGMP = "/proc/net/igmp"
PROC_NETSTAT = "/proc/net/netstat"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content and (content.split()[0].lstrip("-").isdigit()) else default
    except (ValueError, OSError, IndexError):
        return default


def parse_netstat_ipext(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {
        "InMcastPkts": 0,
        "OutMcastPkts": 0,
        "InBcastPkts": 0,
        "OutBcastPkts": 0,
    }
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        for i in range(0, len(lines) - 1, 2):
            if lines[i].startswith("IpExt:"):
                keys = lines[i].split()[1:]
                vals = lines[i + 1].split()[1:]
                for k, v in zip(keys, vals):
                    if k in metrics:
                        try:
                            metrics[k] = int(v)
                        except ValueError:
                            metrics[k] = 0
                break
    except Exception:
        pass
    return metrics


def evaluate_ipv4_igmp(
    conf_dir: str = CONF_IPV4_BASE,
    ipv4_sys_dir: str = PROC_SYS_IPV4_BASE,
    igmp_path: str = PROC_IGMP,
    netstat_path: str = PROC_NETSTAT,
    min_v3_interval_ms: int = 100,
) -> Dict[str, Any]:
    interfaces: Dict[str, Dict[str, int]] = {}
    issues: List[str] = []
    recommendations: List[str] = []

    if os.path.isdir(conf_dir):
        try:
            for entry in sorted(os.listdir(conf_dir)):
                iface_dir = os.path.join(conf_dir, entry)
                if not os.path.isdir(iface_dir):
                    continue

                force_v = read_sysctl_int(os.path.join(iface_dir, "force_igmp_version"), default=-1)
                v2_intvl = read_sysctl_int(os.path.join(iface_dir, "igmpv2_unsolicited_report_interval"), default=-1)
                v3_intvl = read_sysctl_int(os.path.join(iface_dir, "igmpv3_unsolicited_report_interval"), default=-1)

                if force_v != -1 or v3_intvl != -1:
                    interfaces[entry] = {
                        "force_igmp_version": force_v,
                        "igmpv2_unsolicited_report_interval": v2_intvl,
                        "igmpv3_unsolicited_report_interval": v3_intvl,
                    }

                    if force_v == 1:
                        issues.append(f"Legacy IGMPv1 forced on {entry} (force_igmp_version=1)")
                        recommendations.append(f"Set /proc/sys/net/ipv4/conf/{entry}/force_igmp_version to 0 (auto)")

                    if v3_intvl <= 0 and v3_intvl != -1:
                        issues.append(f"Invalid IGMPv3 unsolicited report interval on {entry} ({v3_intvl}ms <= 0)")
                    elif v3_intvl > 0 and v3_intvl < min_v3_interval_ms:
                        issues.append(
                            f"Aggressive IGMPv3 unsolicited report interval below minimum threshold ({min_v3_interval_ms}ms): "
                            f"{entry} ({v3_intvl}ms)"
                        )
                        recommendations.append(f"Increase /proc/sys/net/ipv4/conf/{entry}/igmpv3_unsolicited_report_interval to >= {min_v3_interval_ms}ms")
        except OSError:
            pass

    igmp_qrv = read_sysctl_int(os.path.join(ipv4_sys_dir, "igmp_qrv"), default=2)
    igmp_max_msf = read_sysctl_int(os.path.join(ipv4_sys_dir, "igmp_max_msf"), default=10)
    igmp_max_memberships = read_sysctl_int(os.path.join(ipv4_sys_dir, "igmp_max_memberships"), default=20)

    if igmp_qrv < 1 or igmp_qrv > 7:
        issues.append(f"Invalid or fragile IGMP Querier Robustness Variable (igmp_qrv={igmp_qrv}); RFC 3376 mandates QRV between 1 and 7")
        recommendations.append("Set /proc/sys/net/ipv4/igmp_qrv to standard 2")

    if igmp_max_memberships < 5:
        issues.append(f"Constrained IGMP max memberships limit ({igmp_max_memberships} < 5)")
        recommendations.append("Set /proc/sys/net/ipv4/igmp_max_memberships to >= 20")

    if igmp_max_msf < 2:
        issues.append(f"Constrained IGMP source filter limit ({igmp_max_msf} < 2)")
        recommendations.append("Set /proc/sys/net/ipv4/igmp_max_msf to >= 10")

    active_igmp_groups = 0
    if os.path.isfile(igmp_path):
        try:
            with open(igmp_path, "r", encoding="utf-8", errors="replace") as f:
                for line in f.read().splitlines():
                    parts = line.strip().split()
                    if parts and len(parts[0]) == 8 and all(c in "0123456789ABCDEFabcdef" for c in parts[0]):
                        active_igmp_groups += 1
        except Exception:
            pass

    netstat_m = parse_netstat_ipext(netstat_path)

    all_force = interfaces.get("all", {}).get("force_igmp_version", -1)
    default_force = interfaces.get("default", {}).get("force_igmp_version", -1)
    default_v2 = interfaces.get("default", {}).get("igmpv2_unsolicited_report_interval", 10000)
    default_v3 = interfaces.get("default", {}).get("igmpv3_unsolicited_report_interval", 1000)

    status = "WARNING" if issues else "HEALTHY"

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "pattern": 296,
        "name": "ipv4_igmp",
        "status": status,
        "healthy": len(issues) == 0,
        "interfaces_audited": len(interfaces),
        "igmp_qrv": igmp_qrv,
        "igmp_max_memberships": igmp_max_memberships,
        "igmp_max_msf": igmp_max_msf,
        "all_force_igmp_version": all_force,
        "default_force_igmp_version": default_force,
        "default_igmpv2_interval_ms": default_v2,
        "default_igmpv3_interval_ms": default_v3,
        "in_mcast_pkts": netstat_m["InMcastPkts"],
        "out_mcast_pkts": netstat_m["OutMcastPkts"],
        "in_bcast_pkts": netstat_m["InBcastPkts"],
        "out_bcast_pkts": netstat_m["OutBcastPkts"],
        "active_igmp_groups": active_igmp_groups,
        "interfaces": interfaces,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Audit Linux IPv4 Internet Group Management Protocol (IGMP) & Multicast Policy (Pattern 296 / Pattern 434)"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--conf-dir", default=CONF_IPV4_BASE, help="Path to /proc/sys/net/ipv4/conf")
    parser.add_argument("--sys-dir", default=PROC_SYS_IPV4_BASE, help="Path to /proc/sys/net/ipv4")
    parser.add_argument("--igmp-file", default=PROC_IGMP, help="Path to /proc/net/igmp")
    parser.add_argument("--netstat-file", default=PROC_NETSTAT, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    data = evaluate_ipv4_igmp(
        conf_dir=args.conf_dir,
        ipv4_sys_dir=args.sys_dir,
        igmp_path=args.igmp_file,
        netstat_path=args.netstat_file,
    )

    if args.json:
        print(json.dumps(data, indent=2))
    else:
        print(f"[{data['status']}] Pattern 296 - IPv4 IGMP & Multicast Policy Guard")
        print(f"  Interfaces Audited: {data['interfaces_audited']}")
        print(f"  IGMP QRV: {data['igmp_qrv']} (RFC 3376 default: 2)")
        print(f"  IGMP Max Memberships: {data['igmp_max_memberships']} (default: 20)")
        print(f"  IGMP Max Source Filters: {data['igmp_max_msf']} (default: 10)")
        print(f"  Default Force Version: {data['default_force_igmp_version']} (0=auto RFC 3376 v3)")
        print(f"  Default IGMPv2 Interval: {data['default_igmpv2_interval_ms']}ms")
        print(f"  Default IGMPv3 Interval: {data['default_igmpv3_interval_ms']}ms")
        print(f"  Inbound Multicast Pkts: {data['in_mcast_pkts']:,}")
        print(f"  Outbound Multicast Pkts: {data['out_mcast_pkts']:,}")
        print(f"  Inbound Broadcast Pkts: {data['in_bcast_pkts']:,}")
        print(f"  Outbound Broadcast Pkts: {data['out_bcast_pkts']:,}")
        print(f"  Active IGMP Groups: {data['active_igmp_groups']}")
        if data["issues"]:
            print("  Issues:")
            for issue in data["issues"]:
                print(f"    - {issue}")
        else:
            print("  Issues: None (100% compliant)")

    sys.exit(0 if data["healthy"] else 1)


if __name__ == "__main__":
    main()
