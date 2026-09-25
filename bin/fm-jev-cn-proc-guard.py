#!/usr/bin/env python3
"""
bin/fm-jev-cn-proc-guard.py - Linux Process Events Connector & Netlink Guard (Pattern 305 / Pattern 443)

Audits Linux kernel Netlink Connector subsystem and process lifecycle event monitoring:
  - /proc/net/connector: Registered kernel connector drivers (verifies cn_proc driver registration, ID '1:1')
  - /proc/net/netlink: Active NETLINK_CONNECTOR (protocol family 11) sockets, unread buffer queues, and packet drops

Invariants:
  - cn_proc must be registered in /proc/net/connector with ID '1:1'.
  - NETLINK_CONNECTOR sockets must experience 0 packet drops.
  - rmem and wmem queue backlog must not exceed maximum queue bytes (default 1MB).
  - Fail-open: graceful fallback when proc files are restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

PROC_CONNECTOR = "/proc/net/connector"
PROC_NETLINK = "/proc/net/netlink"
NETLINK_CONNECTOR_FAMILY = 11


def parse_connector_drivers(path: str) -> Dict[str, str]:
    drivers: Dict[str, str] = {}
    if not os.path.isfile(path):
        return drivers
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        for line in lines[1:]:
            parts = line.split()
            if len(parts) >= 2:
                drivers[parts[0]] = parts[1]
    except OSError:
        pass
    return drivers


def parse_netlink_connector_sockets(path: str) -> List[Dict[str, Any]]:
    sockets: List[Dict[str, Any]] = []
    if not os.path.isfile(path):
        return sockets
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        if not lines:
            return sockets
        for line in lines[1:]:
            cols = line.split()
            if len(cols) >= 9:
                try:
                    eth = int(cols[1])
                    if eth == NETLINK_CONNECTOR_FAMILY:
                        sockets.append(
                            {
                                "sk": cols[0],
                                "eth": eth,
                                "pid": int(cols[2]),
                                "groups": cols[3],
                                "rmem": int(cols[4]),
                                "wmem": int(cols[5]),
                                "dump": int(cols[6]),
                                "locks": int(cols[7]),
                                "drops": int(cols[8]),
                                "inode": int(cols[9]) if len(cols) > 9 else 0,
                            }
                        )
                except (ValueError, IndexError):
                    continue
    except OSError:
        pass
    return sockets


def evaluate_cn_proc(
    connector_file: str = PROC_CONNECTOR,
    netlink_file: str = PROC_NETLINK,
    max_drops: int = 0,
    max_queue_bytes: int = 1048576,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    drivers = parse_connector_drivers(connector_file)
    cn_proc_registered = "cn_proc" in drivers
    cn_proc_id = drivers.get("cn_proc", "")

    if not cn_proc_registered:
        issues.append(
            "Kernel process events connector 'cn_proc' is not registered in /proc/net/connector; "
            "process lifecycle event monitoring is inactive"
        )
        recommendations.append("Ensure kernel module 'cn' and CONFIG_PROC_EVENTS are enabled")
        status = "WARNING"
    elif cn_proc_id != "1:1":
        issues.append(
            f"Unexpected cn_proc connector ID '{cn_proc_id}' (expected '1:1'); driver interface mismatch"
        )
        recommendations.append("Verify kernel connector subsystem driver compatibility")
        status = "WARNING"

    sockets = parse_netlink_connector_sockets(netlink_file)
    total_drops = sum(s.get("drops", 0) for s in sockets)
    max_rmem = max((s.get("rmem", 0) for s in sockets), default=0)
    max_wmem = max((s.get("wmem", 0) for s in sockets), default=0)

    if total_drops > max_drops:
        issues.append(
            f"Elevated NETLINK_CONNECTOR packet drops detected: {total_drops} drops across {len(sockets)} sockets"
        )
        recommendations.append("Increase netlink receive buffer size (rmem_default / rmem_max) or optimize listener")
        status = "CRITICAL"

    if max_rmem > max_queue_bytes or max_wmem > max_queue_bytes:
        issues.append(
            f"NETLINK_CONNECTOR queue backlog exceeds threshold: rmem={max_rmem} B, wmem={max_wmem} B (> {max_queue_bytes} B)"
        )
        recommendations.append("Inspect connector listener daemon for event processing latency")
        if status != "CRITICAL":
            status = "WARNING"

    healthy = len(issues) == 0

    return {
        "pattern": 305,
        "name": "cn_proc",
        "description": "Linux Process Events Connector & Netlink Guard",
        "status": status,
        "healthy": healthy,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "cn_proc_registered": cn_proc_registered,
        "cn_proc_id": cn_proc_id,
        "registered_drivers": drivers,
        "connector_socket_count": len(sockets),
        "total_drops": total_drops,
        "max_rmem_bytes": max_rmem,
        "max_wmem_bytes": max_wmem,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Linux Process Events Connector & Netlink Guard (Pattern 305 / Pattern 443)"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--connector-file", default=PROC_CONNECTOR, help="Path to /proc/net/connector")
    parser.add_argument("--netlink-file", default=PROC_NETLINK, help="Path to /proc/net/netlink")
    args = parser.parse_args()

    result = evaluate_cn_proc(
        connector_file=args.connector_file,
        netlink_file=args.netlink_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] Pattern {result['pattern']} - {result['description']}")
        print(f"  cn_proc Registered: {result['cn_proc_registered']} (ID: {result['cn_proc_id']})")
        print(f"  Registered Drivers: {result['registered_drivers']}")
        print(f"  Connector Sockets: {result['connector_socket_count']}, Total Drops: {result['total_drops']}")
        print(f"  Queue Backlog: rmem={result['max_rmem_bytes']} B, wmem={result['max_wmem_bytes']} B")
        if result["issues"]:
            print("  Issues:")
            for issue in result["issues"]:
                print(f"    - {issue}")
        if result["recommendations"]:
            print("  Recommendations:")
            for rec in result["recommendations"]:
                print(f"    - {rec}")

    if not result["healthy"]:
        sys.exit(1 if result["status"] == "WARNING" else 2)


if __name__ == "__main__":
    main()
