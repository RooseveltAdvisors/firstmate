#!/usr/bin/env python3
"""
fm-jev-skbuff-guard.py - Jev Multi-Agent Host Network Protocol Memory Pressure & sk_buff Guard (Pattern 100)

Audits Linux host transport protocol memory buffer allocations and kernel memory pressure flags
from /proc/net/protocols, /proc/sys/net/ipv4/tcp_mem, and /proc/sys/net/ipv4/udp_mem.

Inspects active socket counts, memory page consumption per protocol (TCP, UDP, UNIX, RAW, PACKET, MPTCP),
and detects kernel memory pressure assertion (press=yes) before socket buffers are exhausted and packets dropped.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when /proc files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

PROC_PROTOCOLS = "/proc/net/protocols"
SYSCTL_TCP_MEM = "/proc/sys/net/ipv4/tcp_mem"
SYSCTL_UDP_MEM = "/proc/sys/net/ipv4/udp_mem"
PAGE_SIZE_BYTES = 4096


def read_triplet_file(path: Path) -> Tuple[Optional[int], Optional[int], Optional[int]]:
    """Reads 3 page thresholds (min, pressure, max) from a sysctl file."""
    if not path.is_file():
        return None, None, None
    try:
        parts = path.read_text().strip().split()
        if len(parts) >= 3:
            return int(parts[0]), int(parts[1]), int(parts[2])
    except Exception:
        pass
    return None, None, None


def parse_protocols(path: Path) -> List[Dict[str, Any]]:
    """Parses /proc/net/protocols into structured protocol records."""
    if not path.is_file():
        return []

    protocols: List[Dict[str, Any]] = []
    try:
        lines = path.read_text().splitlines()
        for line in lines[1:]:
            parts = line.split()
            if len(parts) >= 5:
                proto_name = parts[0]
                sock_size = int(parts[1]) if parts[1].isdigit() else 0
                sockets = int(parts[2]) if parts[2].isdigit() else 0
                mem_raw = parts[3]
                mem_pages = int(mem_raw) if mem_raw.lstrip("-").isdigit() else 0
                pressure = parts[4].lower()

                protocols.append({
                    "protocol": proto_name,
                    "sock_size": sock_size,
                    "sockets": sockets,
                    "memory_pages": max(0, mem_pages),
                    "memory_bytes": max(0, mem_pages) * PAGE_SIZE_BYTES if mem_pages > 0 else 0,
                    "memory_pressure": pressure == "yes",
                    "pressure_raw": parts[4],
                })
    except Exception:
        pass

    return protocols


def audit_protocol_memory(
    protocols_file: Optional[str] = None,
    tcp_mem_file: Optional[str] = None,
    udp_mem_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits protocol socket memory buffers and kernel memory pressure."""
    proto_path = Path(protocols_file) if protocols_file else Path(PROC_PROTOCOLS)
    tcp_mem_path = Path(tcp_mem_file) if tcp_mem_file else Path(SYSCTL_TCP_MEM)
    udp_mem_path = Path(udp_mem_file) if udp_mem_file else Path(SYSCTL_UDP_MEM)

    tcp_min, tcp_pressure, tcp_max = read_triplet_file(tcp_mem_path)
    udp_min, udp_pressure, udp_max = read_triplet_file(udp_mem_path)

    protocols = parse_protocols(proto_path)

    total_sockets = sum(p["sockets"] for p in protocols)
    active_protocols = [p for p in protocols if p["sockets"] > 0 or p["memory_pages"] > 0 or p["memory_pressure"]]

    issues: List[str] = []

    # Check for active kernel memory pressure
    pressured_protos = [p["protocol"] for p in protocols if p["memory_pressure"]]
    if pressured_protos:
        issues.append(f"Kernel protocol memory pressure actively asserted on: {', '.join(pressured_protos)}")

    # Check TCP / UDP memory against limits
    tcp_record = next((p for p in protocols if p["protocol"] == "TCP"), None)
    udp_record = next((p for p in protocols if p["protocol"] == "UDP"), None)

    tcp_mem_pct = 0.0
    if tcp_record and tcp_max and tcp_max > 0:
        tcp_mem_pct = (tcp_record["memory_pages"] / tcp_max) * 100.0
        if tcp_mem_pct > 80.0:
            issues.append(f"High TCP buffer memory usage ({tcp_mem_pct:.1f}% of {tcp_max} max pages): risk of packet drop")

    udp_mem_pct = 0.0
    if udp_record and udp_max and udp_max > 0:
        udp_mem_pct = (udp_record["memory_pages"] / udp_max) * 100.0
        if udp_mem_pct > 80.0:
            issues.append(f"High UDP buffer memory usage ({udp_mem_pct:.1f}% of {udp_max} max pages): risk of datagram drop")

    if total_sockets > 10000:
        issues.append(f"High global socket count across protocols ({total_sockets} > 10,000)")

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "total_sockets": total_sockets,
            "active_protocol_count": len(active_protocols),
            "pressured_protocols": pressured_protos,
            "tcp_memory_pages": tcp_record["memory_pages"] if tcp_record else 0,
            "tcp_memory_pct": round(tcp_mem_pct, 2),
            "udp_memory_pages": udp_record["memory_pages"] if udp_record else 0,
            "udp_memory_pct": round(udp_mem_pct, 2),
            "tcp_mem_limits": {"min": tcp_min, "pressure": tcp_pressure, "max": tcp_max},
            "udp_mem_limits": {"min": udp_min, "pressure": udp_pressure, "max": udp_max},
            "issues": issues,
        },
        "active_protocols": active_protocols,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network Protocol Memory Pressure Guard (Pattern 100)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--protocols-file", type=str, default=None, help="Path to /proc/net/protocols")
    parser.add_argument("--tcp-mem-file", type=str, default=None, help="Path to tcp_mem")
    parser.add_argument("--udp-mem-file", type=str, default=None, help="Path to udp_mem")
    args = parser.parse_args()

    result = audit_protocol_memory(
        protocols_file=args.protocols_file,
        tcp_mem_file=args.tcp_mem_file,
        udp_mem_file=args.udp_mem_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Protocol Memory Pressure Guard (Centennial Pattern 100)")
    print("================================================================================")
    print(f" Timestamp:                 {result['timestamp']}")
    print(f" Status:                    {status_color}{summary['status']}{reset_color}")
    print(f" Total Active Sockets:      {summary['total_sockets']}")
    print(f" Active Protocols:          {summary['active_protocol_count']}")
    print(f" Pressured Protocols:       {', '.join(summary['pressured_protocols']) if summary['pressured_protocols'] else 'None'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Protocol':<16} {'Sockets':<10} {'Mem (Pages)':<15} {'Mem (MB)':<12} {'Pressure'}")
    print("--------------------------------------------------------------------------------")
    for proto in result["active_protocols"]:
        mem_mb = proto["memory_bytes"] / (1024 * 1024)
        press_label = "YES (ALERT)" if proto["memory_pressure"] else proto["pressure_raw"]
        print(f" {proto['protocol']:<16} {proto['sockets']:<10} {proto['memory_pages']:<15} {mem_mb:<12.2f} {press_label}")

    if summary["issues"]:
        print("\nActive Protocol Memory Buffer Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll transport protocol socket buffers, sk_buff allocations, and memory limits nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
