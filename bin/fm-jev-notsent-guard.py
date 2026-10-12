#!/usr/bin/env python3
"""
fm-jev-notsent-guard.py - Jev Multi-Agent Host Network TCP Socket Write Queue & Unsent Bufferbloat Guard (Pattern 128)

Audits Linux TCP unsent write queue low-water mark (/proc/sys/net/ipv4/tcp_notsent_lowat),
core socket write buffers (/proc/sys/net/ipv4/tcp_wmem, /proc/sys/net/core/wmem_max),
and scans active socket transmission and reception queues from /proc/net/tcp and /proc/net/tcp6.

In multi-agent telemetry egress, SSE streaming, and high-concurrency RPC topologies,
unbounded socket write buffers accumulate megabytes of unsent data, causing local bufferbloat,
severe RTT inflation, and head-of-line blocking for high-priority cancellation and ping frames.

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

SYSCTL_NOTSENT_LOWAT = "/proc/sys/net/ipv4/tcp_notsent_lowat"
SYSCTL_AUTOCORKING = "/proc/sys/net/ipv4/tcp_autocorking"
SYSCTL_WMEM = "/proc/sys/net/ipv4/tcp_wmem"
SYSCTL_CORE_WMEM_MAX = "/proc/sys/net/core/wmem_max"

PROC_TCP = "/proc/net/tcp"
PROC_TCP6 = "/proc/net/tcp6"

BLOAT_THRESHOLD_BYTES = 262144  # 256 KiB


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def read_wmem(path: Path) -> Tuple[int, int, int]:
    """Reads min, default, max wmem integers."""
    if not path.is_file():
        return 4096, 16384, 4194304
    try:
        parts = path.read_text().split()
        if len(parts) >= 3:
            return int(parts[0]), int(parts[1]), int(parts[2])
    except Exception:
        pass
    return 4096, 16384, 4194304


def scan_socket_queues(path: Path) -> Tuple[int, int, int, int, List[Dict[str, Any]]]:
    """Scans /proc/net/tcp or /proc/net/tcp6 for socket queue depths."""
    if not path.is_file():
        return 0, 0, 0, 0, []

    total_sockets = 0
    total_tx = 0
    total_rx = 0
    max_tx = 0
    bloated_sockets: List[Dict[str, Any]] = []

    try:
        lines = path.read_text().splitlines()
        if len(lines) > 1:
            for line in lines[1:]:
                parts = line.strip().split()
                if len(parts) >= 5:
                    total_sockets += 1
                    tx_rx = parts[4].split(":")
                    if len(tx_rx) == 2:
                        try:
                            tx = int(tx_rx[0], 16)
                            rx = int(tx_rx[1], 16)
                            total_tx += tx
                            total_rx += rx
                            if tx > max_tx:
                                max_tx = tx
                            if tx >= BLOAT_THRESHOLD_BYTES:
                                bloated_sockets.append({
                                    "local_address": parts[1],
                                    "remote_address": parts[2],
                                    "tx_queue_bytes": tx,
                                    "rx_queue_bytes": rx,
                                })
                        except ValueError:
                            continue
    except Exception:
        return total_sockets, total_tx, total_rx, max_tx, bloated_sockets

    return total_sockets, total_tx, total_rx, max_tx, bloated_sockets


def audit_notsent(
    notsent_lowat_file: Optional[str] = None,
    autocorking_file: Optional[str] = None,
    wmem_file: Optional[str] = None,
    core_wmem_file: Optional[str] = None,
    tcp_file: Optional[str] = None,
    tcp6_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host TCP unsent write queue low-water mark and socket queue depths."""
    notsent_p = Path(notsent_lowat_file or SYSCTL_NOTSENT_LOWAT)
    autocork_p = Path(autocorking_file or SYSCTL_AUTOCORKING)
    wmem_p = Path(wmem_file or SYSCTL_WMEM)
    core_wmem_p = Path(core_wmem_file or SYSCTL_CORE_WMEM_MAX)

    tcp_p = Path(tcp_file or PROC_TCP)
    tcp6_p = Path(tcp6_file or PROC_TCP6)

    notsent_lowat = read_int_file(notsent_p)
    if notsent_lowat is None:
        notsent_lowat = 4294967295

    autocorking = read_int_file(autocork_p)
    if autocorking is None:
        autocorking = 1

    core_wmem_max = read_int_file(core_wmem_p)
    if core_wmem_max is None:
        core_wmem_max = 212992

    wmem_min, wmem_def, wmem_max = read_wmem(wmem_p)

    soc4_cnt, tx4, rx4, max_tx4, bloat4 = scan_socket_queues(tcp_p)
    soc6_cnt, tx6, rx6, max_tx6, bloat6 = scan_socket_queues(tcp6_p)

    total_sockets = soc4_cnt + soc6_cnt
    total_tx_bytes = tx4 + tx6
    total_rx_bytes = rx4 + rx6
    peak_tx_bytes = max(max_tx4, max_tx6)
    total_bloated = len(bloat4) + len(bloat6)

    issues: List[str] = []
    healthy = True

    if total_bloated > 0:
        healthy = False
        issues.append(f"Detected {total_bloated} socket(s) with excessive write queue depth (>= {BLOAT_THRESHOLD_BYTES // 1024} KiB).")

    if total_tx_bytes > 52428800:  # 50 MiB
        healthy = False
        issues.append(f"Total host TCP write queue bloat: {total_tx_bytes:,} bytes in unsent transit buffers.")

    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "tcp_notsent_lowat": notsent_lowat,
            "tcp_autocorking": autocorking,
            "total_sockets": total_sockets,
            "total_tx_bytes": total_tx_bytes,
            "total_rx_bytes": total_rx_bytes,
            "peak_tx_bytes": peak_tx_bytes,
            "bloated_sockets_count": total_bloated,
            "wmem_max_bytes": wmem_max,
            "issues": issues,
        },
        "counters": {
            "ipv4_sockets": soc4_cnt,
            "ipv6_sockets": soc6_cnt,
            "ipv4_tx_bytes": tx4,
            "ipv6_tx_bytes": tx6,
            "peak_ipv4_tx_bytes": max_tx4,
            "peak_ipv6_tx_bytes": max_tx6,
            "bloated_ipv4_count": len(bloat4),
            "bloated_ipv6_count": len(bloat6),
        },
        "bloated_sockets": bloat4 + bloat6,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Socket Write Queue & Unsent Bufferbloat Guard (Pattern 128)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--notsent-file", type=str, default=None, help="Path to tcp_notsent_lowat")
    parser.add_argument("--autocorking-file", type=str, default=None, help="Path to tcp_autocorking")
    parser.add_argument("--wmem-file", type=str, default=None, help="Path to tcp_wmem")
    parser.add_argument("--core-wmem-file", type=str, default=None, help="Path to /proc/sys/net/core/wmem_max")
    parser.add_argument("--tcp-file", type=str, default=None, help="Path to /proc/net/tcp")
    parser.add_argument("--tcp6-file", type=str, default=None, help="Path to /proc/net/tcp6")
    args = parser.parse_args()

    result = audit_notsent(
        notsent_lowat_file=args.notsent_file,
        autocorking_file=args.autocorking_file,
        wmem_file=args.wmem_file,
        core_wmem_file=args.core_wmem_file,
        tcp_file=args.tcp_file,
        tcp6_file=args.tcp6_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP Unsent Queue & Bufferbloat Guard (Pattern 128)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Unsent Lowat (tcp_notsent):    {summary['tcp_notsent_lowat']} ({'Unlimited (Default)' if summary['tcp_notsent_lowat'] >= 4294967295 else str(summary['tcp_notsent_lowat']) + ' bytes'})")
    print(f" TCP Autocorking:               {summary['tcp_autocorking']} ({'Active' if summary['tcp_autocorking'] == 1 else 'Disabled'})")
    print(f" Total TCP Sockets Audited:     {summary['total_sockets']} (IPv4: {counters['ipv4_sockets']}, IPv6: {counters['ipv6_sockets']})")
    print(f" Total Unsent Data in Queues:   {summary['total_tx_bytes']:,} bytes ({summary['total_tx_bytes'] / 1024:.2f} KiB)")
    print(f" Peak Single-Socket Write Queue:{summary['peak_tx_bytes']:,} bytes")
    print(f" Bloated Sockets (>= 256 KiB):  {summary['bloated_sockets_count']}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Socket Queue Metric':<35} {'Count / Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Total Unsent Transit Data':<35} {summary['total_tx_bytes']:<15} {'Nominal' if summary['total_tx_bytes'] < 52428800 else 'WARNING'}")
    print(f" {'Peak Socket Write Queue':<35} {summary['peak_tx_bytes']:<15} {'Nominal' if summary['peak_tx_bytes'] < 262144 else 'WARNING'}")
    print(f" {'Bloated Sockets Count':<35} {summary['bloated_sockets_count']:<15} {'Nominal' if summary['bloated_sockets_count'] == 0 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive Write Bufferbloat Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP socket write queues, unsent buffers, and transit headroom nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
