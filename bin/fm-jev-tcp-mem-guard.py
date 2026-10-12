#!/usr/bin/env python3
"""
bin/fm-jev-tcp-mem-guard.py - Host Network TCP Memory Pressure, Prune & Queue Drop Guard (Pattern 223)

Audits Linux kernel TCP memory allocation, socket buffer pressure, and packet drop counters:
  - /proc/net/netstat (TcpExt: TCPMemoryPressures, TCPAbortOnMemory, PruneCalled, RcvPruned, OfoPruned, TCPBacklogDrop, TCPRcvQDrop, TCPZeroWindowDrop)
  - /proc/sys/net/ipv4/tcp_mem (min, pressure, max page limits)
  - /proc/net/sockstat (TCP allocated pages vs kernel pressure & max thresholds)

Detects kernel socket memory exhaustion, write/receive buffer pruning, connection aborts due to memory starvation,
and socket queue drops before TCP latency spikes or agent communication collapses.

Invariants:
  - Read-only diagnostics. Safe, passive, and non-destructive.
  - Fail-open: graceful fallback when /proc files are missing or restricted.
  - Bounded sub-millisecond execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Optional, Tuple


def parse_netstat_file(path: str) -> Dict[str, Dict[str, int]]:
    """Parse /proc/net/netstat format (header line followed by value line)."""
    sections: Dict[str, Dict[str, int]] = {}
    if not os.path.exists(path):
        return sections

    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = [line.strip() for line in f if line.strip()]
    except Exception:
        return sections

    i = 0
    while i < len(lines) - 1:
        header_line = lines[i]
        val_line = lines[i + 1]
        i += 2

        if ":" not in header_line or ":" not in val_line:
            continue

        h_prefix, h_keys = header_line.split(":", 1)
        v_prefix, v_vals = val_line.split(":", 1)

        if h_prefix.strip() != v_prefix.strip():
            continue

        prefix = h_prefix.strip()
        keys = h_keys.strip().split()
        raw_vals = v_vals.strip().split()

        section_data: Dict[str, int] = {}
        for k, v in zip(keys, raw_vals):
            try:
                section_data[k] = int(v)
            except ValueError:
                continue
        sections[prefix] = section_data

    return sections


def parse_tcp_mem_limits(path: str) -> Tuple[int, int, int]:
    """Parse /proc/sys/net/ipv4/tcp_mem (min, pressure, max pages)."""
    if not os.path.exists(path):
        return 762738, 1016987, 1525476  # Typical fallback

    try:
        with open(path, "r", encoding="utf-8") as f:
            parts = f.read().strip().split()
            if len(parts) >= 3:
                return int(parts[0]), int(parts[1]), int(parts[2])
    except Exception:
        pass
    return 762738, 1016987, 1525476


def parse_sockstat_tcp_mem(path: str) -> Dict[str, int]:
    """Parse /proc/net/sockstat to find TCP inuse, orphan, tw, alloc, mem."""
    stats = {"inuse": 0, "orphan": 0, "tw": 0, "alloc": 0, "mem": 0}
    if not os.path.exists(path):
        return stats

    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("TCP:"):
                    parts = line.split()[1:]
                    for idx in range(0, len(parts) - 1, 2):
                        k = parts[idx].lower()
                        try:
                            v = int(parts[idx + 1])
                            if k in stats:
                                stats[k] = v
                        except ValueError:
                            continue
    except Exception:
        pass
    return stats


def audit_tcp_memory(
    netstat_path: str = "/proc/net/netstat",
    tcp_mem_path: str = "/proc/sys/net/ipv4/tcp_mem",
    sockstat_path: str = "/proc/net/sockstat",
    warn_mem_pct: float = 80.0,
    warn_drop_count: int = 500,
) -> Dict[str, Any]:
    netstat = parse_netstat_file(netstat_path)
    tcpext = netstat.get("TcpExt", {})
    ipext = netstat.get("IpExt", {})

    mem_min, mem_pressure, mem_max = parse_tcp_mem_limits(tcp_mem_path)
    sockstat_tcp = parse_sockstat_tcp_mem(sockstat_path)

    current_mem_pages = sockstat_tcp.get("mem", 0)
    page_size_kb = 4  # Linux standard x86_64 page size = 4096 bytes
    current_mem_mb = round((current_mem_pages * page_size_kb) / 1024, 2)
    pressure_mb = round((mem_pressure * page_size_kb) / 1024, 2)
    max_mb = round((mem_max * page_size_kb) / 1024, 2)

    pressure_pct = round((current_mem_pages / mem_pressure * 100), 2) if mem_pressure > 0 else 0.0
    max_pct = round((current_mem_pages / mem_max * 100), 2) if mem_max > 0 else 0.0

    # Key memory pressure metrics
    tcp_mem_pressures = tcpext.get("TCPMemoryPressures", 0)
    tcp_mem_pressures_chrono = tcpext.get("TCPMemoryPressuresChrono", 0)
    tcp_abort_on_mem = tcpext.get("TCPAbortOnMemory", 0)
    prune_called = tcpext.get("PruneCalled", 0)
    rcv_pruned = tcpext.get("RcvPruned", 0)
    ofo_pruned = tcpext.get("OfoPruned", 0)

    # Key drop metrics
    tcp_backlog_drop = tcpext.get("TCPBacklogDrop", 0)
    tcp_rcv_q_drop = tcpext.get("TCPRcvQDrop", 0)
    tcp_zero_window_drop = tcpext.get("TCPZeroWindowDrop", 0)
    tcp_req_q_full_drop = tcpext.get("TCPReqQFullDrop", 0)
    pf_memalloc_drop = tcpext.get("PFMemallocDrop", 0)
    reasm_overlaps = ipext.get("ReasmOverlaps", 0)

    total_critical_drops = (
        tcp_abort_on_mem + tcp_backlog_drop + pf_memalloc_drop + tcp_req_q_full_drop
    )
    total_pruned_packets = rcv_pruned + ofo_pruned

    status = "HEALTHY"
    reasons: List[str] = []

    if current_mem_pages >= mem_max or tcp_abort_on_mem > 0:
        status = "CRITICAL"
        if current_mem_pages >= mem_max:
            reasons.append(f"TCP memory reached hard limit: {current_mem_pages}/{mem_max} pages ({current_mem_mb} MB)")
        if tcp_abort_on_mem > 0:
            reasons.append(f"TCP connections aborted due to memory exhaustion: {tcp_abort_on_mem}")
    elif current_mem_pages >= mem_pressure or pressure_pct >= warn_mem_pct:
        status = "WARNING"
        reasons.append(f"TCP memory in pressure zone: {current_mem_pages}/{mem_pressure} pages ({pressure_pct}% of pressure threshold)")
    elif tcp_backlog_drop > warn_drop_count:
        status = "WARNING"
        reasons.append(f"Elevated TCP backlog drops: {tcp_backlog_drop}")
    elif pf_memalloc_drop > 0:
        status = "WARNING"
        reasons.append(f"Page fault memory allocation drops detected: {pf_memalloc_drop}")

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "reasons": reasons,
        "tcp_memory": {
            "current_pages": current_mem_pages,
            "current_mb": current_mem_mb,
            "pressure_pages": mem_pressure,
            "pressure_mb": pressure_mb,
            "max_pages": mem_max,
            "max_mb": max_mb,
            "pressure_pct": pressure_pct,
            "max_pct": max_pct,
        },
        "sockstat_tcp": sockstat_tcp,
        "pressure_counters": {
            "tcp_memory_pressures": tcp_mem_pressures,
            "tcp_memory_pressures_chrono": tcp_mem_pressures_chrono,
            "tcp_abort_on_memory": tcp_abort_on_mem,
            "prune_called": prune_called,
            "rcv_pruned": rcv_pruned,
            "ofo_pruned": ofo_pruned,
            "total_pruned": total_pruned_packets,
        },
        "drop_counters": {
            "tcp_backlog_drop": tcp_backlog_drop,
            "tcp_rcv_q_drop": tcp_rcv_q_drop,
            "tcp_zero_window_drop": tcp_zero_window_drop,
            "tcp_req_q_full_drop": tcp_req_q_full_drop,
            "pf_memalloc_drop": pf_memalloc_drop,
            "reasm_overlaps": reasm_overlaps,
            "critical_drops": total_critical_drops,
        },
        "sources": {
            "netstat": netstat_path,
            "tcp_mem": tcp_mem_path,
            "sockstat": sockstat_path,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Audit Host Network TCP Memory Pressure, Prune & Queue Drop Guard (Pattern 223)"
    )
    parser.add_argument("--netstat-file", default="/proc/net/netstat", help="Path to /proc/net/netstat")
    parser.add_argument("--tcp-mem-file", default="/proc/sys/net/ipv4/tcp_mem", help="Path to /proc/sys/net/ipv4/tcp_mem")
    parser.add_argument("--sockstat-file", default="/proc/net/sockstat", help="Path to /proc/net/sockstat")
    parser.add_argument("--warn-mem-pct", type=float, default=80.0, help="Warning memory threshold percentage")
    parser.add_argument("--warn-drop-threshold", type=int, default=500, help="Warning drop threshold count")
    parser.add_argument("--json", action="store_true", help="Output JSON telemetry")

    args = parser.parse_args()
    report = audit_tcp_memory(
        netstat_path=args.netstat_file,
        tcp_mem_path=args.tcp_mem_file,
        sockstat_path=args.sockstat_file,
        warn_mem_pct=args.warn_mem_pct,
        warn_drop_count=args.warn_drop_threshold,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        status = report["status"]
        mem = report["tcp_memory"]
        press = report["pressure_counters"]
        drops = report["drop_counters"]
        print(f"[{status}] TCP Memory Pressure & Drop Guard:")
        print(f"  Allocated: {mem['current_pages']} pages ({mem['current_mb']} MB) | Pressure: {mem['pressure_mb']} MB | Max: {mem['max_mb']} MB ({mem['pressure_pct']}% of pressure)")
        print(f"  Memory Pressures: {press['tcp_memory_pressures']} | Aborts on Memory: {press['tcp_abort_on_memory']} | Prunes: {press['prune_called']} (Rcv: {press['rcv_pruned']}, Ofo: {press['ofo_pruned']})")
        print(f"  Queue Drops: Backlog={drops['tcp_backlog_drop']}, RcvQ={drops['tcp_rcv_q_drop']}, ZeroWindow={drops['tcp_zero_window_drop']}, PFMemalloc={drops['pf_memalloc_drop']}")
        if report["reasons"]:
            for r in report["reasons"]:
                print(f"  - {r}")

    if report["status"] == "CRITICAL":
        sys.exit(2)
    elif report["status"] == "WARNING":
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
