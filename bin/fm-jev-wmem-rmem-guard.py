#!/usr/bin/env python3
"""
bin/fm-jev-wmem-rmem-guard.py - Host Network TCP Socket Memory Limits & Auto-Tuning Buffer Guard (Pattern 190)

Audits kernel TCP socket receive/send memory buffer limits (tcp_rmem, tcp_wmem), system-wide TCP
memory pressure thresholds (tcp_mem), core socket memory caps (rmem_max, wmem_max), and dynamic
receive window auto-tuning (tcp_moderate_rcvbuf). Inspects /proc/net/netstat memory counters
(TCPMemoryPressures, TCPMemoryPressuresChrono, TCPRcvQDrop, TCPWqueueTooBig, TCPZeroWindowDrop,
TCPAbortOnMemory, TCPBacklogDrop, PFMemallocDrop). Prevents socket memory exhaustion, bufferbloat,
and receive queue packet drops under high-concurrency LLM inference streams and agent RPC mesh.
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Optional, Tuple


def read_sysctl_int(path: str) -> int:
    if not os.path.exists(path):
        return -1
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception as e:
        print(f"Warning: unable to read {path}: {e}", file=sys.stderr)
        return -1


def read_sysctl_triplet(path: str) -> Tuple[int, int, int]:
    if not os.path.exists(path):
        return (-1, -1, -1)
    try:
        with open(path, "r", encoding="utf-8") as f:
            parts = f.read().strip().split()
            if len(parts) >= 3:
                return (int(parts[0]), int(parts[1]), int(parts[2]))
    except Exception as e:
        print(f"Warning: unable to read triplet from {path}: {e}", file=sys.stderr)
    return (-1, -1, -1)


def parse_netstat_ext(path: str = "/proc/net/netstat") -> Dict[str, int]:
    counters: Dict[str, int] = {}
    if not os.path.exists(path):
        return counters
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
        for i in range(0, len(lines), 2):
            if i + 1 >= len(lines):
                break
            headers = lines[i].split()
            values = lines[i + 1].split()
            if len(headers) == len(values) and headers[0] == "TcpExt:" and values[0] == "TcpExt:":
                for h, v in zip(headers[1:], values[1:]):
                    try:
                        counters[h] = int(v)
                    except ValueError:
                        continue
    except Exception as e:
        print(f"Warning: unable to parse netstat {path}: {e}", file=sys.stderr)
    return counters


def audit_socket_memory(
    tcp_rmem_file: str = "/proc/sys/net/ipv4/tcp_rmem",
    tcp_wmem_file: str = "/proc/sys/net/ipv4/tcp_wmem",
    tcp_mem_file: str = "/proc/sys/net/ipv4/tcp_mem",
    core_rmem_max_file: str = "/proc/sys/net/core/rmem_max",
    core_wmem_max_file: str = "/proc/sys/net/core/wmem_max",
    moderate_rcvbuf_file: str = "/proc/sys/net/ipv4/tcp_moderate_rcvbuf",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    rmem_min, rmem_def, rmem_max = read_sysctl_triplet(tcp_rmem_file)
    wmem_min, wmem_def, wmem_max = read_sysctl_triplet(tcp_wmem_file)
    mem_low, mem_press, mem_high = read_sysctl_triplet(tcp_mem_file)

    core_rmem_max = read_sysctl_int(core_rmem_max_file)
    core_wmem_max = read_sysctl_int(core_wmem_max_file)
    moderate_rcvbuf = read_sysctl_int(moderate_rcvbuf_file)

    netstat = parse_netstat_ext(netstat_file)

    mem_pressures = netstat.get("TCPMemoryPressures", 0)
    mem_pressures_chrono = netstat.get("TCPMemoryPressuresChrono", 0)
    rcv_q_drop = netstat.get("TCPRcvQDrop", 0)
    wqueue_too_big = netstat.get("TCPWqueueTooBig", 0)
    zero_window_drop = netstat.get("TCPZeroWindowDrop", 0)
    abort_on_memory = netstat.get("TCPAbortOnMemory", 0)
    backlog_drop = netstat.get("TCPBacklogDrop", 0)
    memalloc_drop = netstat.get("PFMemallocDrop", 0)

    issues: List[str] = []
    status = "HEALTHY"

    # Critical checks
    if abort_on_memory > 100:
        issues.append(f"TCPAbortOnMemory ({abort_on_memory}) indicates severe kernel memory exhaustion aborting sockets")
        status = "CRITICAL"
    if memalloc_drop > 100:
        issues.append(f"PFMemallocDrop ({memalloc_drop}) indicates packet drops due to kernel page allocator failures")
        status = "CRITICAL"
    if moderate_rcvbuf == 0 and rmem_max < 65536:
        issues.append(f"tcp_moderate_rcvbuf is disabled and tcp_rmem max ({rmem_max}B) is critically small (< 64KB)")
        status = "CRITICAL"
    if mem_high > 0 and mem_high < 10000:
        issues.append(f"tcp_mem high ({mem_high} pages) is dangerously restrictive for multi-agent workloads")
        status = "CRITICAL"

    # Warning checks
    if status != "CRITICAL":
        if mem_pressures > 100:
            issues.append(f"TCPMemoryPressures ({mem_pressures}) indicates active socket buffer pressure events")
            status = "WARNING"
        if wqueue_too_big > 1000:
            issues.append(f"TCPWqueueTooBig ({wqueue_too_big}) indicates sockets exceeding write buffer allocations")
            status = "WARNING"
        if rcv_q_drop > 10000:
            issues.append(f"TCPRcvQDrop ({rcv_q_drop}) exceeds 10,000 packets: receive queues overflowing")
            status = "WARNING"
        if moderate_rcvbuf == 0:
            issues.append("tcp_moderate_rcvbuf is 0: dynamic receive buffer auto-tuning is disabled")
            status = "WARNING"
        if rmem_max > 0 and rmem_max < 1048576:
            issues.append(f"tcp_rmem max ({rmem_max} bytes) < 1MB: may constrain high-throughput RPC sync")
            status = "WARNING"
        if wmem_max > 0 and wmem_max < 1048576:
            issues.append(f"tcp_wmem max ({wmem_max} bytes) < 1MB: may constrain high-throughput RPC send")
            status = "WARNING"

    summary = {
        "status": status,
        "healthy": (status == "HEALTHY"),
        "tcp_rmem_min": rmem_min,
        "tcp_rmem_default": rmem_def,
        "tcp_rmem_max": rmem_max,
        "tcp_wmem_min": wmem_min,
        "tcp_wmem_default": wmem_def,
        "tcp_wmem_max": wmem_max,
        "tcp_mem_low_pages": mem_low,
        "tcp_mem_pressure_pages": mem_press,
        "tcp_mem_high_pages": mem_high,
        "core_rmem_max": core_rmem_max,
        "core_wmem_max": core_wmem_max,
        "tcp_moderate_rcvbuf": moderate_rcvbuf,
        "memory_pressures": mem_pressures,
        "memory_pressures_chrono_ms": mem_pressures_chrono,
        "rcv_q_drop": rcv_q_drop,
        "wqueue_too_big": wqueue_too_big,
        "zero_window_drop": zero_window_drop,
        "abort_on_memory": abort_on_memory,
        "backlog_drop": backlog_drop,
        "memalloc_drop": memalloc_drop,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_rmem": [rmem_min, rmem_def, rmem_max],
            "tcp_wmem": [wmem_min, wmem_def, wmem_max],
            "tcp_mem": [mem_low, mem_press, mem_high],
            "rmem_max": core_rmem_max,
            "wmem_max": core_wmem_max,
            "tcp_moderate_rcvbuf": moderate_rcvbuf,
        },
        "netstat_counters": {
            "TCPMemoryPressures": mem_pressures,
            "TCPMemoryPressuresChrono": mem_pressures_chrono,
            "TCPRcvQDrop": rcv_q_drop,
            "TCPWqueueTooBig": wqueue_too_big,
            "TCPZeroWindowDrop": zero_window_drop,
            "TCPAbortOnMemory": abort_on_memory,
            "TCPBacklogDrop": backlog_drop,
            "PFMemallocDrop": memalloc_drop,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Socket Memory Limits & Auto-Tuning Buffer Guard (Pattern 190)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_socket_memory()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Socket Memory Guard (Pattern 190) - Status: {s['status']}")
    print(f"  tcp_rmem (min/def/max):  {s['tcp_rmem_min']:,} / {s['tcp_rmem_default']:,} / {s['tcp_rmem_max']:,} bytes")
    print(f"  tcp_wmem (min/def/max):  {s['tcp_wmem_min']:,} / {s['tcp_wmem_default']:,} / {s['tcp_wmem_max']:,} bytes")
    print(f"  tcp_mem (low/press/hi):  {s['tcp_mem_low_pages']:,} / {s['tcp_mem_pressure_pages']:,} / {s['tcp_mem_high_pages']:,} pages")
    print(f"  core rmem_max / wmem_max: {s['core_rmem_max']:,} / {s['core_wmem_max']:,} bytes")
    print(f"  tcp_moderate_rcvbuf:     {s['tcp_moderate_rcvbuf']} ({'auto-tuning enabled' if s['tcp_moderate_rcvbuf'] == 1 else 'disabled'})")
    print(f"  TCP Memory Pressures:    {s['memory_pressures']} ({s['memory_pressures_chrono_ms']} ms total)")
    print(f"  Receive Queue Drops:     {s['rcv_q_drop']:,}")
    print(f"  Write Queue Overflows:   {s['wqueue_too_big']:,}")
    print(f"  Zero Window Drops:       {s['zero_window_drop']:,}")
    print(f"  Aborts on Memory:        {s['abort_on_memory']:,}")
    print(f"  Backlog Drops:           {s['backlog_drop']:,}")
    print(f"  Memalloc Drops:          {s['memalloc_drop']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
