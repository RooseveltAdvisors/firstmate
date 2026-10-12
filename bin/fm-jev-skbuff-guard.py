#!/usr/bin/env python3
"""
bin/fm-jev-skbuff-guard.py - Host Network Kernel Socket Buffer Auto-Tuning & Protocol Memory Pressure Guard (Pattern 208)

Audits Linux kernel network socket buffer architectures, dynamic auto-tuning, and protocol memory pressure:
  - /proc/net/protocols (active protocols, socket counts, slab sizes, allocated memory pages, pressure flags)
  - /proc/sys/net/core/rmem_default, rmem_max, wmem_default, wmem_max, optmem_max
  - /proc/sys/net/ipv4/tcp_rmem, tcp_wmem, tcp_moderate_rcvbuf, tcp_window_scaling

Detects active protocol memory pressure flags (press == yes), socket buffer auto-tuning disablers,
ancillary memory starvation (optmem_max bottlenecks on IPC SCM_RIGHTS), and transport window caps.

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
from typing import Any, Dict, List, Tuple


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception:
        return default


def read_sysctl_triplet(path: str, default: Tuple[int, int, int] = (-1, -1, -1)) -> Tuple[int, int, int]:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            parts = [int(x) for x in f.read().strip().split()]
            if len(parts) >= 3:
                return parts[0], parts[1], parts[2]
    except Exception:
        pass
    return default


def parse_proc_net_protocols(path: str = "/proc/net/protocols") -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    protocols: List[Dict[str, Any]] = []
    stats: Dict[str, Any] = {
        "total_sockets": 0,
        "total_protocols": 0,
        "pressured_protocols": [],
        "tcp_sockets": 0,
        "udp_sockets": 0,
        "unix_sockets": 0,
        "packet_sockets": 0,
        "raw_sockets": 0,
    }
    if not os.path.exists(path):
        return protocols, stats

    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = [line.strip() for line in f if line.strip()]
        if len(lines) <= 1:
            return protocols, stats

        header = lines[0].split()
        col_map = {name: idx for idx, name in enumerate(header)}

        for line in lines[1:]:
            parts = line.split()
            if len(parts) < 5:
                continue

            proto_name = parts[0]
            size = int(parts[col_map.get("size", 1)]) if "size" in col_map else 0
            sockets = int(parts[col_map.get("sockets", 2)]) if "sockets" in col_map else 0
            mem_raw = parts[col_map.get("memory", 3)] if "memory" in col_map else "-1"
            press = parts[col_map.get("press", 4)] if "press" in col_map else "NI"

            try:
                mem_pages = int(mem_raw)
            except ValueError:
                mem_pages = -1

            stats["total_protocols"] += 1
            if sockets > 0:
                stats["total_sockets"] += sockets

            proto_upper = proto_name.upper()
            if "TCP" in proto_upper:
                stats["tcp_sockets"] += sockets
            elif "UDP" in proto_upper:
                stats["udp_sockets"] += sockets
            elif "UNIX" in proto_upper:
                stats["unix_sockets"] += sockets
            elif "PACKET" in proto_upper:
                stats["packet_sockets"] += sockets
            elif "RAW" in proto_upper:
                stats["raw_sockets"] += sockets

            if press.lower() == "yes":
                stats["pressured_protocols"].append(proto_name)

            protocols.append({
                "protocol": proto_name,
                "size_bytes": size,
                "sockets": sockets,
                "memory_pages": mem_pages,
                "pressure": press,
            })
    except Exception:
        pass

    return protocols, stats


def audit_skbuff_guard(
    proc_protocols: str = "/proc/net/protocols",
    proc_sys_core: str = "/proc/sys/net/core",
    proc_sys_ipv4: str = "/proc/sys/net/ipv4",
) -> Dict[str, Any]:
    protocols, proto_stats = parse_proc_net_protocols(proc_protocols)

    rmem_default = read_sysctl_int(os.path.join(proc_sys_core, "rmem_default"), 212992)
    rmem_max = read_sysctl_int(os.path.join(proc_sys_core, "rmem_max"), 212992)
    wmem_default = read_sysctl_int(os.path.join(proc_sys_core, "wmem_default"), 212992)
    wmem_max = read_sysctl_int(os.path.join(proc_sys_core, "wmem_max"), 212992)
    optmem_max = read_sysctl_int(os.path.join(proc_sys_core, "optmem_max"), 131072)

    tcp_rmem = read_sysctl_triplet(os.path.join(proc_sys_ipv4, "tcp_rmem"), (4096, 131072, 33554432))
    tcp_wmem = read_sysctl_triplet(os.path.join(proc_sys_ipv4, "tcp_wmem"), (4096, 16384, 4194304))
    tcp_moderate = read_sysctl_int(os.path.join(proc_sys_ipv4, "tcp_moderate_rcvbuf"), 1)
    tcp_scaling = read_sysctl_int(os.path.join(proc_sys_ipv4, "tcp_window_scaling"), 1)

    issues: List[str] = []
    status = "HEALTHY"

    if proto_stats["pressured_protocols"]:
        issues.append(
            f"CRITICAL: Active protocol memory pressure detected on: {', '.join(proto_stats['pressured_protocols'])}"
        )
        status = "CRITICAL"

    if proto_stats["total_sockets"] > 10000:
        issues.append(
            f"CRITICAL: High total socket allocations ({proto_stats['total_sockets']:,} sockets across protocols)"
        )
        status = "CRITICAL"
    elif proto_stats["total_sockets"] > 4000:
        issues.append(
            f"WARNING: Elevated socket allocations ({proto_stats['total_sockets']:,} sockets across protocols)"
        )
        if status != "CRITICAL":
            status = "WARNING"

    if tcp_scaling == 0:
        issues.append("CRITICAL: tcp_window_scaling disabled; maximum window capped at 64 KB")
        status = "CRITICAL"

    if tcp_moderate == 0:
        issues.append("WARNING: tcp_moderate_rcvbuf disabled; dynamic receive buffer auto-tuning inactive")
        if status != "CRITICAL":
            status = "WARNING"

    if optmem_max < 20480:
        issues.append(f"WARNING: optmem_max ({optmem_max} bytes) unusually low; risk of ENOBUFS in IPC fd passing")
        if status != "CRITICAL":
            status = "WARNING"

    healthy = status == "HEALTHY"
    recommendation = (
        "Kernel socket buffer auto-tuning, protocol memory allocations, and window scaling are nominal."
        if healthy
        else "; ".join(issues)
    )

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "total_sockets": proto_stats["total_sockets"],
            "total_protocols": proto_stats["total_protocols"],
            "tcp_sockets": proto_stats["tcp_sockets"],
            "udp_sockets": proto_stats["udp_sockets"],
            "unix_sockets": proto_stats["unix_sockets"],
            "packet_sockets": proto_stats["packet_sockets"],
            "raw_sockets": proto_stats["raw_sockets"],
            "pressured_protocols": proto_stats["pressured_protocols"],
            "rmem_default_bytes": rmem_default,
            "rmem_max_bytes": rmem_max,
            "wmem_default_bytes": wmem_default,
            "wmem_max_bytes": wmem_max,
            "optmem_max_bytes": optmem_max,
            "tcp_rmem_min_bytes": tcp_rmem[0],
            "tcp_rmem_default_bytes": tcp_rmem[1],
            "tcp_rmem_max_bytes": tcp_rmem[2],
            "tcp_wmem_min_bytes": tcp_wmem[0],
            "tcp_wmem_default_bytes": tcp_wmem[1],
            "tcp_wmem_max_bytes": tcp_wmem[2],
            "tcp_moderate_rcvbuf": tcp_moderate,
            "tcp_window_scaling": tcp_scaling,
            "issues": issues,
            "recommendation": recommendation,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network Kernel Socket Buffer Auto-Tuning & Protocol Memory Pressure Guard (Pattern 208)"
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON telemetry")
    args = parser.parse_args()

    report = audit_skbuff_guard()
    s = report["summary"]

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"[{s['status']}] Pattern 208: Host Network Socket Buffer Auto-Tuning & Protocol Memory Guard")
        print(
            f"  Allocated Sockets: {s['total_sockets']:,} total (tcp: {s['tcp_sockets']:,}, "
            f"unix: {s['unix_sockets']:,}, udp: {s['udp_sockets']:,}, packet: {s['packet_sockets']:,})"
        )
        print(
            f"  Core Buffers: rmem_max={s['rmem_max_bytes']:,} B, wmem_max={s['wmem_max_bytes']:,} B, "
            f"optmem_max={s['optmem_max_bytes']:,} B"
        )
        print(
            f"  TCP Buffers: rmem=[{s['tcp_rmem_min_bytes']:,}, {s['tcp_rmem_default_bytes']:,}, {s['tcp_rmem_max_bytes']:,}], "
            f"wmem=[{s['tcp_wmem_min_bytes']:,}, {s['tcp_wmem_default_bytes']:,}, {s['tcp_wmem_max_bytes']:,}]"
        )
        print(
            f"  Auto-Tuning: moderate_rcvbuf={'enabled' if s['tcp_moderate_rcvbuf'] else 'disabled'}, "
            f"window_scaling={'enabled' if s['tcp_window_scaling'] else 'disabled'}"
        )
        print(f"  Recommendation: {s['recommendation']}")

    return 0 if s["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
