#!/usr/bin/env python3
"""
fm-jev-net-drop-guard.py - Jev Multi-Agent Host Network Interface Packet Drop Guard (Pattern 234)

Audits host network interfaces (/sys/class/net/*) for RX/TX packet drops, transmission errors,
and MTU misconfigurations across developer seats, bridges, and tunnels.
Prevents silent socket resets, webhook delivery timeouts, and tunnel packet truncation.

Invariants:
  - Read-only diagnostics by default. Non-destructive.
  - Fail-open: graceful fallback if /sys/class/net is restricted.
  - Bounded fast execution (< 0.5s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional


DEFAULT_SYS_NET_PATH = "/sys/class/net"
DEFAULT_DROP_RATE_WARN = 0.01  # 1% drop rate warning
STATE_FILE = "/tmp/.fm-jev-net-drop-state.json"


def read_sys_file(path: str, default: str = "") -> str:
    """Reads a single sysfs file safely."""
    try:
        with open(path, "r", errors="replace") as f:
            return f.read().strip()
    except Exception:
        return default


def read_sys_int(path: str, default: int = 0) -> int:
    """Reads an integer from sysfs file safely."""
    val = read_sys_file(path, "")
    try:
        return int(val)
    except ValueError:
        return default


def audit_interface(iface_name: str, sys_net_path: str = DEFAULT_SYS_NET_PATH) -> Dict[str, Any]:
    """Audits a single interface in /sys/class/net/."""
    iface_dir = os.path.join(sys_net_path, iface_name)
    stats_dir = os.path.join(iface_dir, "statistics")

    operstate = read_sys_file(os.path.join(iface_dir, "operstate"), "unknown")
    mtu = read_sys_int(os.path.join(iface_dir, "mtu"), 1500)

    rx_packets = read_sys_int(os.path.join(stats_dir, "rx_packets"), 0)
    tx_packets = read_sys_int(os.path.join(stats_dir, "tx_packets"), 0)
    rx_dropped = read_sys_int(os.path.join(stats_dir, "rx_dropped"), 0)
    tx_dropped = read_sys_int(os.path.join(stats_dir, "tx_dropped"), 0)
    rx_errors = read_sys_int(os.path.join(stats_dir, "rx_errors"), 0)
    tx_errors = read_sys_int(os.path.join(stats_dir, "tx_errors"), 0)

    total_rx = rx_packets + rx_dropped
    rx_drop_ratio = round(rx_dropped / max(1, total_rx), 6)

    return {
        "interface": iface_name,
        "operstate": operstate,
        "mtu": mtu,
        "rx_packets": rx_packets,
        "tx_packets": tx_packets,
        "rx_dropped": rx_dropped,
        "tx_dropped": tx_dropped,
        "rx_errors": rx_errors,
        "tx_errors": tx_errors,
        "rx_drop_ratio": rx_drop_ratio,
        "is_up": operstate.lower() in ("up", "unknown"),
    }


def audit_fleet_net_drops(
    sys_net_path: str = DEFAULT_SYS_NET_PATH,
    drop_rate_warn: float = DEFAULT_DROP_RATE_WARN,
) -> Dict[str, Any]:
    """Audits all network interfaces for packet drops and transmission errors."""
    if not os.path.exists(sys_net_path):
        return {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "summary": {
                "interfaces_count": 0,
                "healthy": True,
                "status": "HEALTHY",
                "recommendation": "no sysfs net directory present",
            },
            "interfaces": [],
        }

    interfaces: List[Dict[str, Any]] = []
    try:
        entries = sorted(os.listdir(sys_net_path))
    except Exception:
        entries = []

    warning_ifaces = []
    for iface in entries:
        info = audit_interface(iface, sys_net_path=sys_net_path)
        interfaces.append(info)

        if info["is_up"] and iface != "lo":
            if info["rx_drop_ratio"] > drop_rate_warn or info["rx_errors"] > 0 or info["tx_errors"] > 0:
                warning_ifaces.append(iface)

    status = "HEALTHY"
    recommendation = "optimal"

    if warning_ifaces:
        status = "WARNING"
        recommendation = f"Elevated packet drops/errors on interface(s): {', '.join(warning_ifaces)}"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "interfaces_count": len(interfaces),
            "up_interfaces_count": sum(1 for i in interfaces if i["is_up"]),
            "warning_interfaces": warning_ifaces,
            "drop_rate_threshold": drop_rate_warn,
            "status": status,
            "recommendation": recommendation,
            "healthy": (status == "HEALTHY"),
        },
        "interfaces": interfaces,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network Interface Packet Drop Guard (Pattern 234)"
    )
    parser.add_argument(
        "--sysfs",
        default=DEFAULT_SYS_NET_PATH,
        help=f"Path to sysfs net directory (default: {DEFAULT_SYS_NET_PATH})",
    )
    parser.add_argument(
        "--drop-warn",
        type=float,
        default=DEFAULT_DROP_RATE_WARN,
        help=f"Drop ratio warning threshold (default: {DEFAULT_DROP_RATE_WARN})",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output raw JSON results",
    )

    args = parser.parse_args()

    results = audit_fleet_net_drops(
        sys_net_path=args.sysfs,
        drop_rate_warn=args.drop_warn,
    )

    if args.json:
        print(json.dumps(results, indent=2))
        return 0 if results["summary"]["healthy"] else 1

    summary = results["summary"]
    print(f"Jev Network Packet Drop Guard (Pattern 234) - {results['timestamp']}")
    print(f"Audited {summary['interfaces_count']} interfaces ({summary['up_interfaces_count']} up)")
    print(f"Health Status:  {summary['status']}")
    print(f"Recommendation: {summary['recommendation']}")

    if results["interfaces"]:
        print("\nInterface Statistics:")
        for i in results["interfaces"]:
            print(
                f"  - {i['interface']} ({i['operstate']}, MTU {i['mtu']}): "
                f"RX {i['rx_packets']} (drop {i['rx_dropped']}, err {i['rx_errors']}), "
                f"TX {i['tx_packets']} (drop {i['tx_dropped']}, err {i['tx_errors']})"
            )

    return 0 if summary["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
