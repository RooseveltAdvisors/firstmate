#!/usr/bin/env python3
"""
fm-jev-prune-guard.py - Jev Multi-Agent Host Network TCP Receive Queue Pruning & Buffer Collapse Guard (Pattern 138)

Audits Linux TCP receive buffer allocation policy (/proc/sys/net/ipv4/tcp_rmem,
/proc/sys/net/ipv4/tcp_mem, /proc/sys/net/ipv4/tcp_moderate_rcvbuf) and receive queue
exhaustion / buffer collapse counters from /proc/net/netstat (PruneCalled, RcvPruned,
OfoPruned, TCPMemoryPressures, TCPRcvCollapsed, TCPRcvQDrop, TCPZeroWindowDrop).

In multi-agent architectures where high-concurrency LLM streaming sessions, tool call
subprocesses, and high-frequency RPC connections share host network buffers, socket
receive queues can become overwhelmed if an agent process is momentarily busy parsing JSON
or executing tools. When receive buffers fill:
  1. The kernel attempts `tcp_collapse()` to defragment SKBs and recover overhead (TCPRcvCollapsed).
  2. If memory remains exhausted, the kernel calls `tcp_prune_queue()` (PruneCalled), shedding
     out-of-order packets (OfoPruned) or even in-sequence packets (RcvPruned), forcing retransmits.
  3. If global TCP memory limits are exceeded, the stack enters memory pressure (TCPMemoryPressures).

This guard monitors buffer collapse efficiency, pruning rates, and memory pressure triggers,
ensuring multi-agent streaming connections never silently stall from socket starvation.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysctl or procfs entries are inaccessible.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SYSCTL_TCP_RMEM = "/proc/sys/net/ipv4/tcp_rmem"
SYSCTL_TCP_MEM = "/proc/sys/net/ipv4/tcp_mem"
SYSCTL_TCP_MODERATE_RCVBUF = "/proc/sys/net/ipv4/tcp_moderate_rcvbuf"
PROC_NETSTAT = "/proc/net/netstat"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def read_int_tuple(path: Path) -> Optional[Tuple[int, int, int]]:
    """Reads a tuple of 3 integers (min, default, max) from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        parts = path.read_text().split()
        if len(parts) >= 3:
            return int(parts[0]), int(parts[1]), int(parts[2])
    except Exception:
        pass
    return None


def parse_proc_pairs(path: Path, section_name: str) -> Dict[str, int]:
    """Parses paired header/metric lines from /proc/net/netstat."""
    if not path.is_file():
        return {}

    metrics: Dict[str, int] = {}
    try:
        lines = path.read_text().splitlines()
        for i in range(0, len(lines) - 1):
            line = lines[i]
            if line.startswith(f"{section_name}:"):
                keys = line.split()[1:]
                next_line = lines[i + 1]
                if next_line.startswith(f"{section_name}:"):
                    vals = next_line.split()[1:]
                    for k, v in zip(keys, vals):
                        try:
                            metrics[k] = int(v)
                        except ValueError:
                            continue
                break
    except Exception:
        pass
    return metrics


def audit_prune_guard(
    rmem_file: Optional[str] = None,
    mem_file: Optional[str] = None,
    moderate_rcvbuf_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TCP receive queue pruning, buffer collapse, and memory pressure metrics."""
    r_path = Path(rmem_file or SYSCTL_TCP_RMEM)
    m_path = Path(mem_file or SYSCTL_TCP_MEM)
    mod_path = Path(moderate_rcvbuf_file or SYSCTL_TCP_MODERATE_RCVBUF)
    netstat_path = Path(netstat_file or PROC_NETSTAT)

    rmem = read_int_tuple(r_path) or (4096, 131072, 6291456)
    tcp_mem = read_int_tuple(m_path) or (187398, 249866, 374796)
    moderate_rcvbuf = read_int_file(mod_path) if mod_path.is_file() else 1
    if moderate_rcvbuf is None:
        moderate_rcvbuf = 1

    netstat_metrics = parse_proc_pairs(netstat_path, "TcpExt")

    prune_called = netstat_metrics.get("PruneCalled", 0)
    rcv_pruned = netstat_metrics.get("RcvPruned", 0)
    ofo_pruned = netstat_metrics.get("OfoPruned", 0)
    memory_pressures = netstat_metrics.get("TCPMemoryPressures", 0)
    rcv_collapsed = netstat_metrics.get("TCPRcvCollapsed", 0)
    rcv_q_drop = netstat_metrics.get("TCPRcvQDrop", 0)
    zero_window_drop = netstat_metrics.get("TCPZeroWindowDrop", 0)
    delivered = netstat_metrics.get("TCPDelivered", 0)

    # Calculate collapse and pruning rates
    base_delivered = max(delivered, 1)
    collapse_ratio_pct = round((rcv_collapsed / base_delivered) * 100, 4)
    total_pruned_packets = rcv_pruned + rcv_q_drop
    prune_ratio_pct = round((total_pruned_packets / base_delivered) * 100, 4)

    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    # Evaluation Rules
    if memory_pressures > 5:
        status = "CRITICAL"
        issues.append(f"Host TCP subsystem entered global memory pressure {memory_pressures} times")
        recommendations.append("Increase net.ipv4.tcp_mem pages or investigate memory-heavy streaming sockets")
    elif memory_pressures > 0:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Host TCP subsystem experienced {memory_pressures} memory pressure events")
        recommendations.append("Monitor socket buffer consumption and check net.ipv4.tcp_mem limits")

    if moderate_rcvbuf != 1:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"TCP receive buffer auto-tuning is disabled (tcp_moderate_rcvbuf={moderate_rcvbuf})")
        recommendations.append("Enable receive buffer auto-tuning: sysctl -w net.ipv4.tcp_moderate_rcvbuf=1")

    # Check maximum receive buffer size (should be at least 2MB for high-throughput streaming)
    if rmem[2] < 2097152:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Maximum TCP receive buffer is low ({rmem[2]} bytes < 2MiB)")
        recommendations.append("Increase net.ipv4.tcp_rmem max limit to at least 4194304 or 8388608 bytes")

    if prune_ratio_pct > 0.1 and total_pruned_packets > 10000:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Significant receive queue packet loss from buffer pruning ({total_pruned_packets:,} packets, {prune_ratio_pct}%)")
        recommendations.append("Increase socket receive buffer ceilings to avoid drop-induced stalls")

    if not recommendations:
        recommendations.append("TCP receive buffer auto-tuning, collapse recovery, and memory envelope operating nominally")

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_moderate_rcvbuf": moderate_rcvbuf,
            "tcp_rmem_min": rmem[0],
            "tcp_rmem_default": rmem[1],
            "tcp_rmem_max": rmem[2],
            "tcp_mem_min_pages": tcp_mem[0],
            "tcp_mem_pressure_pages": tcp_mem[1],
            "tcp_mem_max_pages": tcp_mem[2],
            "prune_called": prune_called,
            "rcv_pruned": rcv_pruned,
            "ofo_pruned": ofo_pruned,
            "tcp_rcv_collapsed": rcv_collapsed,
            "tcp_memory_pressures": memory_pressures,
            "collapse_ratio_pct": collapse_ratio_pct,
            "prune_ratio_pct": prune_ratio_pct,
            "issues": issues,
            "recommendations": recommendations,
        },
        "counters": {
            "prune_called": prune_called,
            "rcv_pruned": rcv_pruned,
            "ofo_pruned": ofo_pruned,
            "rcv_collapsed": rcv_collapsed,
            "memory_pressures": memory_pressures,
            "rcv_q_drop": rcv_q_drop,
            "zero_window_drop": zero_window_drop,
            "tcp_delivered": delivered,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Receive Queue Pruning Guard (Pattern 138)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--rmem-file", type=str, help="Override path to tcp_rmem sysctl")
    parser.add_argument("--mem-file", type=str, help="Override path to tcp_mem sysctl")
    parser.add_argument("--moderate-rcvbuf-file", type=str, help="Override path to tcp_moderate_rcvbuf sysctl")
    parser.add_argument("--netstat-file", type=str, help="Override path to /proc/net/netstat")

    args = parser.parse_args()

    result = audit_prune_guard(
        rmem_file=args.rmem_file,
        mem_file=args.mem_file,
        moderate_rcvbuf_file=args.moderate_rcvbuf_file,
        netstat_file=args.netstat_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    s = result["summary"]
    c = result["counters"]

    print("=== Jev Host Network TCP Receive Queue Pruning Guard (Pattern 138) ===")
    print(f"Status:                    {s['status']}")
    print(f"Receive Buffer Auto-Tuning:{' Enabled' if s['tcp_moderate_rcvbuf'] == 1 else ' Disabled'}")
    print(f"TCP Rcv Buffer Limits:     min={s['tcp_rmem_min']} default={s['tcp_rmem_default']} max={s['tcp_rmem_max']:,} bytes")
    print(f"TCP Memory Limits (pages): min={s['tcp_mem_min_pages']} pressure={s['tcp_mem_pressure_pages']} max={s['tcp_mem_max_pages']}")
    print(f"Buffer Collapse Events:    {s['tcp_rcv_collapsed']:,} ({s['collapse_ratio_pct']}%)")
    print(f"Prune Calls (Buffer Full): {s['prune_called']:,}")
    print(f"Receive Queue Pruned:      {s['rcv_pruned']:,} packets")
    print(f"Out-of-Order Pruned:       {s['ofo_pruned']:,} packets")
    print(f"Memory Pressure Events:    {s['tcp_memory_pressures']:,}")
    print(f"Receive Queue Drops:       {c['rcv_q_drop']:,}")
    print(f"Total Segments Delivered:  {c['tcp_delivered']:,}")

    if s["issues"]:
        print("\nIssues Identified:")
        for issue in s["issues"]:
            print(f"  - [!] {issue}")

    print("\nRecommendations:")
    for rec in s["recommendations"]:
        print(f"  - {rec}")


if __name__ == "__main__":
    main()
