#!/usr/bin/env python3
"""
bin/fm-jev-raw-socket-guard.py - Host Network Raw Socket (SOCK_RAW) Buffer & Dropped Packet Guard (Pattern 222)

Audits Linux kernel raw IPv4 and IPv6 sockets (SOCK_RAW):
  - /proc/net/raw and /proc/net/raw6 (sl, local_address, rem_address, st, tx_queue, rx_queue, uid, inode, drops)
  - Decodes IPv4 (little-endian hex) and IPv6 (128-bit hex) endpoints
  - Tracks queued inbound bytes in rx_queue (unresponsive consumer memory leaks)
  - Tracks queued outbound bytes in tx_queue
  - Audits per-socket kernel drop counters (drops from full socket receive buffers)
  - Identifies socket ownership by UID and inode

Detects abandoned raw sockets from diagnostic tools (ping, traceroute, raw packet monitors, VPN tunnels),
memory accumulation in raw socket queues, and silent packet loss before network telemetry or agent communication degrades.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when /proc/net/raw or raw6 is missing or restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import socket
import struct
import sys
from typing import Any, Dict, List, Optional, Tuple


def decode_ipv4_addr(hex_str: str) -> Tuple[str, int]:
    try:
        parts = hex_str.split(":")
        ip_hex = parts[0]
        port_hex = parts[1] if len(parts) > 1 else "0"
        ip = socket.inet_ntoa(struct.pack("<L", int(ip_hex, 16)))
        port = int(port_hex, 16)
        return ip, port
    except Exception:
        return hex_str, 0


def decode_ipv6_addr(hex_str: str) -> Tuple[str, int]:
    try:
        parts = hex_str.split(":")
        ip_hex = parts[0]
        port_hex = parts[1] if len(parts) > 1 else "0"
        if len(ip_hex) == 32:
            words = [int(ip_hex[i : i + 8], 16) for i in range(0, 32, 8)]
            packed = struct.pack("<IIII", *words)
            ip = socket.inet_ntop(socket.AF_INET6, packed)
        else:
            ip = ip_hex
        port = int(port_hex, 16)
        return ip, port
    except Exception:
        return hex_str, 0


def parse_raw_socket_file(path: str, is_ipv6: bool = False) -> List[Dict[str, Any]]:
    sockets: List[Dict[str, Any]] = []
    if not os.path.exists(path):
        return sockets

    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception:
        return sockets

    if len(lines) <= 1:
        return sockets

    for line in lines[1:]:
        parts = line.strip().split()
        if len(parts) >= 10:
            try:
                sl = parts[0].rstrip(":")
                local_raw = parts[1]
                remote_raw = parts[2]
                st = parts[3]
                queue_part = parts[4]

                if ":" in queue_part:
                    tx_hex, rx_hex = queue_part.split(":")
                    tx_queue = int(tx_hex, 16)
                    rx_queue = int(rx_hex, 16)
                    uid = int(parts[7]) if len(parts) > 7 else 0
                    inode = int(parts[9]) if len(parts) > 9 else 0
                    drops = int(parts[-1]) if len(parts) >= 12 else 0
                else:
                    tx_queue = int(parts[4])
                    rx_queue = int(parts[5])
                    uid = int(parts[8]) if len(parts) > 8 else 0
                    inode = int(parts[10]) if len(parts) > 10 else 0
                    drops = int(parts[-1])

                if is_ipv6:
                    local_ip, local_port = decode_ipv6_addr(local_raw)
                    remote_ip, remote_port = decode_ipv6_addr(remote_raw)
                else:
                    local_ip, local_port = decode_ipv4_addr(local_raw)
                    remote_ip, remote_port = decode_ipv4_addr(remote_raw)

                sockets.append({
                    "family": "IPv6" if is_ipv6 else "IPv4",
                    "sl": sl,
                    "local_ip": local_ip,
                    "local_port": local_port,
                    "remote_ip": remote_ip,
                    "remote_port": remote_port,
                    "state": st,
                    "tx_queue_bytes": tx_queue,
                    "rx_queue_bytes": rx_queue,
                    "uid": uid,
                    "inode": inode,
                    "drops": drops,
                })
            except (ValueError, IndexError):
                continue

    return sockets


def audit_raw_sockets(
    proc_raw_path: str = "/proc/net/raw",
    proc_raw6_path: str = "/proc/net/raw6",
    warn_sockets: int = 25,
    crit_sockets: int = 100,
    warn_rx_bytes: int = 10 * 1024 * 1024,
    crit_rx_bytes: int = 50 * 1024 * 1024,
    warn_drops: int = 100,
    crit_drops: int = 1000,
) -> Dict[str, Any]:
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    raw4 = parse_raw_socket_file(proc_raw_path, is_ipv6=False)
    raw6 = parse_raw_socket_file(proc_raw6_path, is_ipv6=True)
    all_sockets = raw4 + raw6

    total_sockets = len(all_sockets)
    total_rx_bytes = sum(s["rx_queue_bytes"] for s in all_sockets)
    total_tx_bytes = sum(s["tx_queue_bytes"] for s in all_sockets)
    total_drops = sum(s["drops"] for s in all_sockets)
    sockets_with_drops = sum(1 for s in all_sockets if s["drops"] > 0)
    sockets_with_rx = sum(1 for s in all_sockets if s["rx_queue_bytes"] > 0)

    issues: List[str] = []
    status = "HEALTHY"

    if total_sockets >= crit_sockets:
        status = "CRITICAL"
        issues.append(f"Raw socket count critical: {total_sockets} sockets (>= {crit_sockets})")
    elif total_sockets >= warn_sockets:
        status = "WARNING"
        issues.append(f"Raw socket count elevated: {total_sockets} sockets (>= {warn_sockets})")

    if total_rx_bytes >= crit_rx_bytes:
        status = "CRITICAL"
        issues.append(f"Raw socket queued memory critical: {total_rx_bytes / (1024*1024):.2f} MB")
    elif total_rx_bytes >= warn_rx_bytes:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Raw socket queued memory elevated: {total_rx_bytes / (1024*1024):.2f} MB")

    if total_drops >= crit_drops:
        status = "CRITICAL"
        issues.append(f"Raw socket packet drops critical: {total_drops} drops")
    elif total_drops >= warn_drops:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Raw socket packet drops elevated: {total_drops} drops")

    top_rx_sockets = sorted(all_sockets, key=lambda x: x["rx_queue_bytes"], reverse=True)[:5]

    return {
        "timestamp": now,
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "total_raw_sockets": total_sockets,
            "ipv4_raw_sockets": len(raw4),
            "ipv6_raw_sockets": len(raw6),
            "total_rx_queue_bytes": total_rx_bytes,
            "total_tx_queue_bytes": total_tx_bytes,
            "total_drops": total_drops,
            "sockets_with_drops": sockets_with_drops,
            "sockets_with_queued_bytes": sockets_with_rx,
            "issues": issues,
        },
        "sockets": all_sockets,
        "top_memory_sockets": top_rx_sockets,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Host Network Raw Socket (SOCK_RAW) Buffer & Dropped Packet Guard (Pattern 222)"
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    parser.add_argument("--proc-raw", type=str, default="/proc/net/raw", help="Path to /proc/net/raw")
    parser.add_argument("--proc-raw6", type=str, default="/proc/net/raw6", help="Path to /proc/net/raw6")
    parser.add_argument("--warn-sockets", type=int, default=25, help="Warning threshold for raw socket count")
    parser.add_argument("--crit-sockets", type=int, default=100, help="Critical threshold for raw socket count")
    parser.add_argument(
        "--warn-rx-bytes",
        type=int,
        default=10 * 1024 * 1024,
        help="Warning threshold for queued rx bytes (default 10MB)",
    )
    parser.add_argument(
        "--crit-rx-bytes",
        type=int,
        default=50 * 1024 * 1024,
        help="Critical threshold for queued rx bytes (default 50MB)",
    )
    parser.add_argument("--warn-drops", type=int, default=100, help="Warning threshold for dropped packets")
    parser.add_argument("--crit-drops", type=int, default=1000, help="Critical threshold for dropped packets")

    args = parser.parse_args()

    report = audit_raw_sockets(
        proc_raw_path=args.proc_raw,
        proc_raw6_path=args.proc_raw6,
        warn_sockets=args.warn_sockets,
        crit_sockets=args.crit_sockets,
        warn_rx_bytes=args.warn_rx_bytes,
        crit_rx_bytes=args.crit_rx_bytes,
        warn_drops=args.warn_drops,
        crit_drops=args.crit_drops,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(
            f"[{s['status']}] Raw Sockets (SOCK_RAW): {s['total_raw_sockets']} (IPv4: {s['ipv4_raw_sockets']}, IPv6: {s['ipv6_raw_sockets']}) | Queued Rx: {s['total_rx_queue_bytes']} B | Drops: {s['total_drops']}"
        )
        if report["sockets"]:
            print("  Active Raw Sockets:")
            for sock in report["sockets"][:10]:
                print(
                    f"    - [{sock['family']}] {sock['local_ip']}:{sock['local_port']} -> {sock['remote_ip']}:{sock['remote_port']} (rx={sock['rx_queue_bytes']} B, drops={sock['drops']}, uid={sock['uid']})"
                )
        if s["issues"]:
            print("  Issues:")
            for issue in s["issues"]:
                print(f"    - {issue}")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
