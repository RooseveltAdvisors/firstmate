#!/usr/bin/env python3
"""
fm-jev-sockstat-guard.py - Jev Multi-Agent TCP/UDP Socket Buffer & Orphan Connection Guard (Pattern 69)

Audits Linux network socket buffers, orphan sockets, time-wait connections, and memory pressure.
Monitors /proc/net/sockstat and /proc/sys/net/ipv4/tcp_mem to prevent socket exhaustion, orphan socket
leaks, or kernel TCP memory pressure from dropping subagent JSON-RPC streams, LLM inference sockets,
or clearinghouse EDI connections.

Invariants:
  - Read-only diagnostics. Non-destructive.
  - Fail-open: graceful handling on systems with missing IPv6 or restricted procfs.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_WARN_ORPHAN_COUNT = 1000
DEFAULT_WARN_TIMEWAIT_COUNT = 5000
DEFAULT_WARN_PRESSURE_RATIO = 0.80
PAGE_SIZE_KB = 4
SOCKSTAT_PATH = "/proc/net/sockstat"
SOCKSTAT6_PATH = "/proc/net/sockstat6"
TCP_MEM_PATH = "/proc/sys/net/ipv4/tcp_mem"
TCP_MAX_ORPHANS_PATH = "/proc/sys/net/ipv4/tcp_max_orphans"


def parse_sockstat(path: str = SOCKSTAT_PATH) -> Dict[str, Any]:
    """Parses /proc/net/sockstat key-value statistics."""
    data: Dict[str, Any] = {}
    if not os.path.exists(path):
        return data

    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                parts = line.split()
                if not parts:
                    continue
                proto = parts[0].rstrip(":")
                stats = {}
                i = 1
                while i < len(parts) - 1:
                    key = parts[i]
                    val = parts[i + 1]
                    try:
                        stats[key] = int(val)
                    except ValueError:
                        stats[key] = val
                    i += 2
                data[proto] = stats
    except Exception:
        pass

    return data


def parse_tcp_mem(path: str = TCP_MEM_PATH) -> Tuple[int, int, int]:
    """Reads (min, pressure, max) page limits from /proc/sys/net/ipv4/tcp_mem."""
    if not os.path.exists(path):
        return (0, 0, 0)
    try:
        with open(path, "r") as f:
            parts = f.read().strip().split()
            if len(parts) >= 3:
                return (int(parts[0]), int(parts[1]), int(parts[2]))
    except Exception:
        pass
    return (0, 0, 0)


def read_int_val(path: str, default: int = 0) -> int:
    """Reads a single integer sysctl value."""
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r") as f:
            return int(f.read().strip())
    except Exception:
        return default


def audit_sockstat(
    sockstat_path: str = SOCKSTAT_PATH,
    sockstat6_path: str = SOCKSTAT6_PATH,
    tcp_mem_path: str = TCP_MEM_PATH,
    max_orphans_path: str = TCP_MAX_ORPHANS_PATH,
    warn_orphan_count: int = DEFAULT_WARN_ORPHAN_COUNT,
    warn_tw_count: int = DEFAULT_WARN_TIMEWAIT_COUNT,
    warn_pressure_ratio: float = DEFAULT_WARN_PRESSURE_RATIO,
) -> Dict[str, Any]:
    """Performs full fleet audit of network socket buffers and connection pressure."""
    s4 = parse_sockstat(sockstat_path)
    s6 = parse_sockstat(sockstat6_path)
    min_pages, pressure_pages, max_pages = parse_tcp_mem(tcp_mem_path)
    max_orphans = read_int_val(max_orphans_path, default=65536)

    sockets_used = s4.get("sockets", {}).get("used", 0)
    tcp_info = s4.get("TCP", {})
    udp_info = s4.get("UDP", {})

    tcp_inuse = tcp_info.get("inuse", 0)
    tcp_orphan = tcp_info.get("orphan", 0)
    tcp_tw = tcp_info.get("tw", 0)
    tcp_alloc = tcp_info.get("alloc", 0)
    tcp_mem_pages = tcp_info.get("mem", 0)
    tcp_mem_mb = round((tcp_mem_pages * PAGE_SIZE_KB) / 1024.0, 2)

    udp_inuse = udp_info.get("inuse", 0)
    udp_mem_pages = udp_info.get("mem", 0)
    udp_mem_mb = round((udp_mem_pages * PAGE_SIZE_KB) / 1024.0, 2)

    tcp6_inuse = s6.get("TCP6", {}).get("inuse", 0)
    udp6_inuse = s6.get("UDP6", {}).get("inuse", 0)

    pressure_ratio = (tcp_mem_pages / pressure_pages) if pressure_pages > 0 else 0.0
    orphan_ratio = (tcp_orphan / max_orphans) if max_orphans > 0 else 0.0

    status = "HEALTHY"
    recommendation = "Network socket buffers, orphan counts, and TCP memory pressure are nominal."

    if pressure_pages > 0 and tcp_mem_pages >= pressure_pages:
        status = "CRITICAL"
        recommendation = (
            f"Kernel TCP memory is actively under pressure! Consuming {tcp_mem_pages:,} pages ({tcp_mem_mb} MB) "
            f"exceeding watermark of {pressure_pages:,} pages. Network packets and streams are subject to drops."
        )
    elif tcp_orphan >= warn_orphan_count or orphan_ratio >= 0.20:
        status = "WARNING"
        recommendation = (
            f"Elevated orphan socket count ({tcp_orphan:,} orphans, {orphan_ratio*100:.1f}% of max {max_orphans:,}). "
            "Inspect lingering subagent sockets or unclosed SSE connections."
        )
    elif tcp_tw >= warn_tw_count:
        status = "WARNING"
        recommendation = (
            f"High TIME_WAIT socket bucket accumulation ({tcp_tw:,} TIME_WAIT sockets). "
            "Consider enabling tcp_tw_reuse or reusing persistent HTTP connections."
        )
    elif pressure_ratio >= warn_pressure_ratio:
        status = "WARNING"
        recommendation = (
            f"TCP socket memory usage ({tcp_mem_mb} MB, {pressure_ratio*100:.1f}%) is approaching "
            f"pressure threshold ({pressure_pages:,} pages). Monitor buffer allocations."
        )

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": (status == "HEALTHY"),
            "sockets_used": sockets_used,
            "tcp_inuse": tcp_inuse,
            "tcp_orphan": tcp_orphan,
            "tcp_timewait": tcp_tw,
            "tcp_alloc": tcp_alloc,
            "tcp_mem_pages": tcp_mem_pages,
            "tcp_mem_mb": tcp_mem_mb,
            "tcp_pressure_pages": pressure_pages,
            "tcp_pressure_ratio": round(pressure_ratio, 4),
            "tcp_max_orphans": max_orphans,
            "orphan_ratio": round(orphan_ratio, 4),
            "udp_inuse": udp_inuse,
            "udp_mem_mb": udp_mem_mb,
            "ipv6_tcp_inuse": tcp6_inuse,
            "ipv6_udp_inuse": udp6_inuse,
            "recommendation": recommendation,
        },
        "raw_sockstat_v4": s4,
        "raw_sockstat_v6": s6,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent TCP/UDP Socket Buffer & Orphan Connection Guard (Pattern 69)"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument(
        "--warn-orphan-count",
        type=int,
        default=DEFAULT_WARN_ORPHAN_COUNT,
        help=f"Warn threshold for orphan TCP sockets (default: {DEFAULT_WARN_ORPHAN_COUNT})",
    )
    parser.add_argument(
        "--warn-tw-count",
        type=int,
        default=DEFAULT_WARN_TIMEWAIT_COUNT,
        help=f"Warn threshold for TIME_WAIT TCP sockets (default: {DEFAULT_WARN_TIMEWAIT_COUNT})",
    )
    parser.add_argument(
        "--warn-pressure-ratio",
        type=float,
        default=DEFAULT_WARN_PRESSURE_RATIO,
        help=f"Warn threshold for TCP memory pressure ratio (default: {DEFAULT_WARN_PRESSURE_RATIO})",
    )

    args = parser.parse_args()

    report = audit_sockstat(
        warn_orphan_count=args.warn_orphan_count,
        warn_tw_count=args.warn_tw_count,
        warn_pressure_ratio=args.warn_pressure_ratio,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"[{s['status']}] Jev Socket Buffer & Orphan Connection Guard (Pattern 69)")
        print(f"Total Sockets: {s['sockets_used']:,} used | TCP In-Use: {s['tcp_inuse']:,} (IPv6: {s['ipv6_tcp_inuse']}) | UDP In-Use: {s['udp_inuse']:,}")
        print(f"TCP Buffers: {s['tcp_mem_mb']} MB ({s['tcp_mem_pages']:,} pages, pressure: {s['tcp_pressure_pages']:,}) | Ratio: {s['tcp_pressure_ratio']*100:.1f}%")
        print(f"Orphan Sockets: {s['tcp_orphan']:,} / max {s['tcp_max_orphans']:,} | TIME_WAIT: {s['tcp_timewait']:,}")
        print(f"Status: {s['status']}")
        print(f"Recommendation: {s['recommendation']}")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
