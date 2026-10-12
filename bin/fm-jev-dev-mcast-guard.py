#!/usr/bin/env python3
"""
bin/fm-jev-dev-mcast-guard.py - Host Network Device Multicast Filter & Promiscuous Mode Guard (Pattern 213)

Audits Linux kernel L2 device multicast MAC filters and interface promiscuous flags:
  - /proc/net/dev_mcast (L2 hardware multicast filter table entries, refcounts, MAC addresses)
  - /sys/class/net/<iface>/flags (IFF_UP 0x1, IFF_PROMISC 0x100, IFF_ALLMULTI 0x200, IFF_MULTICAST 0x1000)
  - /sys/class/net/<iface>/operstate (interface operational state: up/down)
  - /sys/class/net/<iface>/carrier (physical link carrier detection)

Detects unintended promiscuous packet sniffing (IFF_PROMISC), hardware multicast filter overflow
forcing all-multicast mode (IFF_ALLMULTI), and rogue packet capture processes across multi-agent
workspaces, container veth bridges, and host NICs.

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
from typing import Any, Dict, List


IFF_UP = 0x1
IFF_BROADCAST = 0x2
IFF_PROMISC = 0x100
IFF_ALLMULTI = 0x200
IFF_MULTICAST = 0x1000


def format_hex_mac(raw_hex: str) -> str:
    """Formats a raw hex string (e.g. 01005e000001) into standard colon notation."""
    clean = raw_hex.strip().lower()
    if len(clean) == 12:
        return ":".join(clean[i : i + 2] for i in range(0, 12, 2))
    return raw_hex


def read_sysfs_hex_int(path: str, default: int = 0) -> int:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            content = f.read().strip()
            return int(content, 16) if content.startswith("0x") else int(content)
    except Exception:
        return default


def read_sysfs_str(path: str, default: str = "") -> str:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return default


def parse_dev_mcast(path: str = "/proc/net/dev_mcast") -> Dict[str, List[Dict[str, Any]]]:
    interfaces: Dict[str, List[Dict[str, Any]]] = {}
    if not os.path.exists(path):
        return interfaces

    try:
        with open(path, "r", encoding="utf-8") as f:
            for raw_line in f:
                parts = raw_line.strip().split()
                if len(parts) >= 5:
                    # e.g.: "2    enp7s0          1     0     01005e000001"
                    dev_name = parts[1]
                    refcnt = int(parts[2]) if parts[2].isdigit() else 1
                    is_global = int(parts[3]) if parts[3].isdigit() else 0
                    mac_hex = parts[4]
                    if dev_name not in interfaces:
                        interfaces[dev_name] = []
                    interfaces[dev_name].append({
                        "mac": format_hex_mac(mac_hex),
                        "refcount": refcnt,
                        "is_global": bool(is_global),
                    })
    except Exception:
        pass

    return interfaces


def audit_dev_mcast_guard(
    proc_dev_mcast: str = "/proc/net/dev_mcast",
    sys_net_dir: str = "/sys/class/net",
    allowed_promisc_ifaces: List[str] = None,
) -> Dict[str, Any]:
    if allowed_promisc_ifaces is None:
        allowed_promisc_ifaces = []

    mcast_filters = parse_dev_mcast(proc_dev_mcast)

    interfaces_info: Dict[str, Any] = {}
    total_filters = sum(len(flist) for flist in mcast_filters.values())
    promisc_count = 0
    allmulti_count = 0

    if os.path.isdir(sys_net_dir):
        try:
            for iface in sorted(os.listdir(sys_net_dir)):
                iface_path = os.path.join(sys_net_dir, iface)
                if not os.path.isdir(iface_path):
                    continue

                flags = read_sysfs_hex_int(os.path.join(iface_path, "flags"), 0)
                operstate = read_sysfs_str(os.path.join(iface_path, "operstate"), "unknown")
                carrier = read_sysfs_hex_int(os.path.join(iface_path, "carrier"), 0)

                is_up = bool(flags & IFF_UP)
                is_promisc = bool(flags & IFF_PROMISC)
                is_allmulti = bool(flags & IFF_ALLMULTI)
                is_multicast = bool(flags & IFF_MULTICAST)

                if is_promisc and iface not in allowed_promisc_ifaces:
                    promisc_count += 1
                if is_allmulti:
                    allmulti_count += 1

                flist = mcast_filters.get(iface, [])

                interfaces_info[iface] = {
                    "operstate": operstate,
                    "carrier": carrier,
                    "is_up": is_up,
                    "is_promisc": is_promisc,
                    "is_allmulti": is_allmulti,
                    "is_multicast": is_multicast,
                    "flags_hex": hex(flags),
                    "filter_count": len(flist),
                    "filters": flist,
                }
        except Exception:
            pass

    issues: List[str] = []
    status = "HEALTHY"

    # Evaluation rules
    if promisc_count > 0:
        status = "CRITICAL"
        promisc_devs = [dev for dev, d in interfaces_info.items() if d["is_promisc"] and dev not in allowed_promisc_ifaces]
        issues.append(
            f"CRITICAL: Unauthorized promiscuous mode detected on interface(s): {', '.join(promisc_devs)}. "
            f"Interface is capturing all L2 segment traffic."
        )

    if allmulti_count > 0:
        if status != "CRITICAL":
            status = "WARNING"
        allmulti_devs = [dev for dev, d in interfaces_info.items() if d["is_allmulti"]]
        issues.append(
            f"WARNING: All-multicast (IFF_ALLMULTI) mode active on interface(s): {', '.join(allmulti_devs)}. "
            f"Hardware filter overflow; Delivering all multicast packets to CPU softirqs."
        )

    for dev, d in interfaces_info.items():
        if d["filter_count"] >= 32:
            if status != "CRITICAL":
                status = "WARNING"
            issues.append(
                f"WARNING: High L2 multicast filter count on '{dev}' ({d['filter_count']} MAC filters). "
                f"Approaching typical hardware NIC MAC filter capacity."
            )

    recommendation = (
        "Device multicast filters and interface promiscuous modes are nominal."
        if status == "HEALTHY"
        else "Review active packet capture tools and multicast memberships to avoid promiscuous CPU overhead."
    )

    now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()

    return {
        "timestamp": now_iso,
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "total_interfaces": len(interfaces_info),
            "total_filters": total_filters,
            "promisc_count": promisc_count,
            "allmulti_count": allmulti_count,
            "issues": issues,
            "recommendation": recommendation,
        },
        "interfaces": interfaces_info,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network Device Multicast Filter & Promiscuous Mode Guard (Pattern 213)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results as JSON")
    parser.add_argument("--verbose", "-v", action="store_true", help="Print verbose interface details")
    parser.add_argument("--warn-only", action="store_true", help="Exit 0 even on CRITICAL issues")
    parser.add_argument("--path-dev-mcast", default="/proc/net/dev_mcast", help="Path to /proc/net/dev_mcast")
    parser.add_argument("--path-sys-net", default="/sys/class/net", help="Path to /sys/class/net")
    parser.add_argument("--allow-promisc", action="append", default=[], help="Allowed promiscuous interface")

    args = parser.parse_args()

    data = audit_dev_mcast_guard(
        proc_dev_mcast=args.path_dev_mcast,
        sys_net_dir=args.path_sys_net,
        allowed_promisc_ifaces=args.allow_promisc,
    )

    if args.json:
        print(json.dumps(data, indent=2))
        return 0 if (data["summary"]["healthy"] or args.warn_only) else 1

    summary = data["summary"]
    status = summary["status"]

    color_code = "\033[32m" if status == "HEALTHY" else ("\033[33m" if status == "WARNING" else "\033[31m")
    reset_code = "\033[0m"

    print(f"[{color_code}{status}{reset_code}] Host Device Multicast Filter & Promiscuous Guard (Pattern 213)")
    print(f"  Total Interfaces Audited : {summary['total_interfaces']}")
    print(f"  L2 Multicast MAC Filters : {summary['total_filters']}")
    print(f"  Promiscuous Interfaces   : {summary['promisc_count']}")
    print(f"  All-Multicast Interfaces : {summary['allmulti_count']}")

    if args.verbose and data["interfaces"]:
        print("\n  Interface Status & Filters:")
        for dev, iface_data in data["interfaces"].items():
            promisc_flag = " [PROMISC]" if iface_data["is_promisc"] else ""
            allmulti_flag = " [ALLMULTI]" if iface_data["is_allmulti"] else ""
            print(f"    - {dev:<10}: state={iface_data['operstate']}, filters={iface_data['filter_count']}{promisc_flag}{allmulti_flag}")
            for flt in iface_data.get("filters", []):
                print(f"        MAC: {flt['mac']} (refcount={flt['refcount']})")

    if summary["issues"]:
        print("\n  Issues Detected:")
        for issue in summary["issues"]:
            print(f"    - {issue}")

    print(f"\n  Recommendation: {summary['recommendation']}")

    return 0 if (summary["healthy"] or args.warn_only) else 1


if __name__ == "__main__":
    sys.exit(main())
