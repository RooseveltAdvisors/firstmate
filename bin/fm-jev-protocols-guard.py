#!/usr/bin/env python3
"""
bin/fm-jev-protocols-guard.py - Host Network Kernel Transport Protocol Registry & Socket Memory Pressure Guard (Pattern 247)

Audits Linux kernel transport protocol registry and socket memory pressure from /proc/net/protocols:
  - Registered protocol names and driver modules
  - Active socket counts per transport protocol (TCP, UDP, UNIX, NETLINK, MPTCP, RAW, etc.)
  - Protocol socket memory page allocations and memory pressure states (press: "yes" / "no" / "NI")
  - Dedicated slab cache utilization (slab: "yes" / "no")
  - Protocol structure sizes and maximum header overheads

Invariants:
  - Immediate detection of memory pressure in any active transport protocol (press == "yes").
  - Verification that core transport protocols (TCP, UDP, UNIX-STREAM, UNIX, NETLINK) are registered.
  - Tracking of active socket allocations and slab-backed protocol caches across the fleet host.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when /proc/net/protocols is inaccessible.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

DEFAULT_PROTOCOLS_PATH = "/proc/net/protocols"
CORE_REQUIRED_PROTOCOLS = ["TCP", "UDP", "UNIX-STREAM", "UNIX", "NETLINK"]


def parse_protocols_file(path: str = DEFAULT_PROTOCOLS_PATH) -> List[Dict[str, Any]]:
    entries: List[Dict[str, Any]] = []
    if not os.path.exists(path):
        return entries
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = [l.strip() for l in f if l.strip()]
        if not lines:
            return entries
        headers = lines[0].split()
        for line in lines[1:]:
            parts = line.split()
            if len(parts) >= 8:
                proto_name = parts[0]
                try:
                    obj_size = int(parts[1])
                except ValueError:
                    obj_size = 0
                try:
                    sockets = int(parts[2])
                except ValueError:
                    sockets = 0
                try:
                    memory_pages = int(parts[3])
                except ValueError:
                    memory_pages = -1
                press = parts[4]
                try:
                    maxhdr = int(parts[5])
                except ValueError:
                    maxhdr = 0
                slab = parts[6]
                module = parts[7]

                caps: Dict[str, bool] = {}
                if len(parts) > 8 and len(headers) == len(parts):
                    for h, val in zip(headers[8:], parts[8:]):
                        caps[h] = (val.lower() == "y")

                entries.append({
                    "protocol": proto_name,
                    "size": obj_size,
                    "sockets": sockets,
                    "memory_pages": memory_pages,
                    "memory_pressure": (press.lower() == "yes"),
                    "press_raw": press,
                    "maxhdr": maxhdr,
                    "slab": (slab.lower() == "yes"),
                    "module": module,
                    "capabilities": caps,
                })
    except (OSError, PermissionError):
        pass
    return entries


def audit_protocols_guard(
    protocols_file: str = DEFAULT_PROTOCOLS_PATH,
    core_protocols: List[str] = None,
) -> Dict[str, Any]:
    if core_protocols is None:
        core_protocols = list(CORE_REQUIRED_PROTOCOLS)

    entries = parse_protocols_file(protocols_file)
    total_protocols = len(entries)
    in_use_protocols = [e for e in entries if e.get("sockets", 0) > 0]
    total_sockets = sum(e.get("sockets", 0) for e in entries)
    pressured_protocols = [e.get("protocol") for e in entries if e.get("memory_pressure")]
    slab_protocols = [e.get("protocol") for e in entries if e.get("slab")]
    tracked_memory_pages = sum(e.get("memory_pages", 0) for e in entries if e.get("memory_pages", 0) > 0)

    proto_map = {e.get("protocol"): e for e in entries}

    issues: List[str] = []
    recommendations: List[str] = []

    # Invariant 1: Any protocol under memory pressure
    if pressured_protocols:
        issues.append(
            f"Active kernel socket memory pressure detected on protocols: {', '.join(pressured_protocols)}"
        )
        recommendations.append(
            "Increase sysctl socket memory limits (e.g. net.ipv4.tcp_mem / udp_mem) or terminate leaking sockets"
        )

    # Invariant 2: Missing core protocols
    missing_core = [p for p in core_protocols if p not in proto_map]
    if missing_core:
        issues.append(f"Missing core network protocols in registry: {', '.join(missing_core)}")
        recommendations.append("Verify kernel networking module loading and core protocol support")

    healthy = len(issues) == 0
    if not healthy:
        status = "CRITICAL" if pressured_protocols else "WARNING"
    else:
        status = "HEALTHY"

    active_summary = {
        e.get("protocol"): {
            "sockets": e.get("sockets", 0),
            "memory_pages": e.get("memory_pages", -1),
            "memory_pressure": e.get("memory_pressure", False),
            "slab": e.get("slab", False),
        }
        for e in in_use_protocols
    }

    return {
        "status": status,
        "healthy": healthy,
        "total_protocols": total_protocols,
        "in_use_protocols_count": len(in_use_protocols),
        "total_sockets": total_sockets,
        "pressured_protocols": pressured_protocols,
        "pressured_count": len(pressured_protocols),
        "slab_protocols_count": len(slab_protocols),
        "tracked_memory_pages": tracked_memory_pages,
        "active_protocols": active_summary,
        "core_protocols_verified": [p for p in core_protocols if p in proto_map],
        "protocols": entries,
        "issues": issues,
        "recommendations": recommendations,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network Kernel Transport Protocol Registry & Socket Memory Pressure Guard (Pattern 247)"
    )
    parser.add_argument("--protocols-file", default=DEFAULT_PROTOCOLS_PATH, help="Path to /proc/net/protocols")
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--verbose", action="store_true", help="Verbose reporting")
    args = parser.parse_args()

    result = audit_protocols_guard(protocols_file=args.protocols_file)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] Host Network Kernel Transport Protocol Guard (Pattern 247)")
        print(f"  Total Protocols:         {result['total_protocols']}")
        print(f"  In-Use Protocols:        {result['in_use_protocols_count']}")
        print(f"  Total Sockets:           {result['total_sockets']}")
        print(f"  Pressured Protocols:     {result['pressured_count']}")
        print(f"  Slab-Backed Protocols:   {result['slab_protocols_count']}")
        print(f"  Tracked Memory Pages:    {result['tracked_memory_pages']}")
        print("  Active Protocols:")
        for proto, data in result["active_protocols"].items():
            print(f"    - {proto:12s}: sockets={data['sockets']:<4d} memory_pages={data['memory_pages']} slab={data['slab']}")
        if result["issues"]:
            print("  Issues:")
            for iss in result["issues"]:
                print(f"    - {iss}")
        if result["recommendations"]:
            print("  Recommendations:")
            for rec in result["recommendations"]:
                print(f"    - {rec}")

    return 0 if result["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
