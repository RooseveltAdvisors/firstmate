#!/usr/bin/env python3
"""
bin/fm-jev-udp-guard.py - Host Network UDP Datagram Buffer & Socket Drop Guard (Pattern 215)

Audits Linux kernel UDP datagram queues, socket drops, buffer memory, and protocol errors:
  - /proc/net/udp & /proc/net/udp6 (Active sockets, tx_queue, rx_queue, socket-level drops, inodes)
  - /proc/net/snmp (Udp: InDatagrams, OutDatagrams, RcvbufErrors, SndbufErrors, InCsumErrors, NoPorts, MemErrors)
  - /proc/sys/net/ipv4/udp_mem, udp_rmem_min, udp_wmem_min (Memory buffer limits and pressure thresholds)

Detects UDP socket queue overruns (RcvbufErrors), kernel UDP memory pressure (MemErrors),
checksum corruptions (InCsumErrors), and unbound datagram socket drops across multi-agent
DNS resolvers, RPC multiplexers, telemetry collectors, and host services.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when procfs or sysctl paths are restricted or missing.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Tuple


def read_sysctl_list(path: str, default: List[int]) -> List[int]:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            parts = f.read().strip().split()
            return [int(p) for p in parts if p.isdigit()] or default
    except Exception:
        return default


def read_sysctl_int(path: str, default: int = 0) -> int:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            c = f.read().strip()
            return int(c) if c.isdigit() else default
    except Exception:
        return default


def parse_proc_net_udp(path: str) -> List[Dict[str, Any]]:
    sockets: List[Dict[str, Any]] = []
    if not os.path.exists(path):
        return sockets

    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception:
        return sockets

    for line in lines:
        parts = line.strip().split()
        if not parts or parts[0] == "sl":
            continue
        if len(parts) >= 12:
            try:
                sl = parts[0].rstrip(":")
                local_addr = parts[1]
                rem_addr = parts[2]
                st = parts[3]
                queue_parts = parts[4].split(":")
                tx_queue = int(queue_parts[0], 16) if len(queue_parts) > 0 else 0
                rx_queue = int(queue_parts[1], 16) if len(queue_parts) > 1 else 0
                uid = int(parts[7]) if len(parts) > 7 and parts[7].isdigit() else 0
                inode = int(parts[9]) if len(parts) > 9 and parts[9].isdigit() else 0
                drops = int(parts[12]) if len(parts) > 12 and parts[12].isdigit() else 0

                sockets.append({
                    "slot": sl,
                    "local_address": local_addr,
                    "rem_address": rem_addr,
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


def parse_snmp_udp(path: str = "/proc/net/snmp") -> Dict[str, int]:
    stats: Dict[str, int] = {}
    if not os.path.exists(path):
        return stats

    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception:
        return stats

    headers: List[str] = []
    for line in lines:
        parts = line.strip().split()
        if not parts:
            continue
        if parts[0] == "Udp:" and not headers:
            headers = parts[1:]
        elif parts[0] == "Udp:" and headers:
            values = parts[1:]
            for h, v in zip(headers, values):
                try:
                    stats[h] = int(v)
                except ValueError:
                    continue
            break

    return stats


def audit_udp(
    proc_udp_path: str = "/proc/net/udp",
    proc_udp6_path: str = "/proc/net/udp6",
    proc_snmp_path: str = "/proc/net/snmp",
    sysctl_dir: str = "/proc/sys/net/ipv4",
    warn_rcvbuf_ratio: float = 0.05,
    crit_rcvbuf_ratio: float = 1.0,
    warn_queue_bytes: int = 1048576,
    crit_queue_bytes: int = 8388608,
) -> Dict[str, Any]:
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    v4_sockets = parse_proc_net_udp(proc_udp_path)
    v6_sockets = parse_proc_net_udp(proc_udp6_path)
    all_sockets = v4_sockets + v6_sockets

    snmp = parse_snmp_udp(proc_snmp_path)

    udp_mem = read_sysctl_list(os.path.join(sysctl_dir, "udp_mem"), [1525479, 2033974, 3050958])
    udp_rmem_min = read_sysctl_int(os.path.join(sysctl_dir, "udp_rmem_min"), 4096)
    udp_wmem_min = read_sysctl_int(os.path.join(sysctl_dir, "udp_wmem_min"), 4096)

    total_sockets = len(all_sockets)
    total_socket_drops = sum(s["drops"] for s in all_sockets)
    sockets_with_drops = sum(1 for s in all_sockets if s["drops"] > 0)
    total_rx_queue = sum(s["rx_queue_bytes"] for s in all_sockets)
    total_tx_queue = sum(s["tx_queue_bytes"] for s in all_sockets)
    max_rx_queue = max((s["rx_queue_bytes"] for s in all_sockets), default=0)

    in_datagrams = snmp.get("InDatagrams", 0)
    out_datagrams = snmp.get("OutDatagrams", 0)
    in_errors = snmp.get("InErrors", 0)
    rcvbuf_errors = snmp.get("RcvbufErrors", 0)
    sndbuf_errors = snmp.get("SndbufErrors", 0)
    csum_errors = snmp.get("InCsumErrors", 0)
    mem_errors = snmp.get("MemErrors", 0)
    no_ports = snmp.get("NoPorts", 0)

    rcvbuf_error_ratio = (rcvbuf_errors / in_datagrams * 100.0) if in_datagrams > 0 else 0.0
    in_error_ratio = (in_errors / in_datagrams * 100.0) if in_datagrams > 0 else 0.0

    issues: List[str] = []
    status = "HEALTHY"

    if mem_errors > 0 or rcvbuf_error_ratio >= crit_rcvbuf_ratio or max_rx_queue >= crit_queue_bytes:
        status = "CRITICAL"
        if mem_errors > 0:
            issues.append(f"Kernel UDP memory exhaustion: {mem_errors} MemErrors recorded")
        if rcvbuf_error_ratio >= crit_rcvbuf_ratio:
            issues.append(f"UDP receive buffer drop ratio critical: {rcvbuf_error_ratio:.4f}% ({rcvbuf_errors} / {in_datagrams})")
        if max_rx_queue >= crit_queue_bytes:
            issues.append(f"UDP socket rx_queue critical: {max_rx_queue / (1024*1024):.2f} MB")
    elif rcvbuf_error_ratio >= warn_rcvbuf_ratio or sockets_with_drops > 0 or max_rx_queue >= warn_queue_bytes:
        status = "WARNING"
        if rcvbuf_error_ratio >= warn_rcvbuf_ratio:
            issues.append(f"UDP receive buffer drop ratio elevated: {rcvbuf_error_ratio:.4f}% ({rcvbuf_errors} drops)")
        if sockets_with_drops > 0:
            issues.append(f"Active UDP sockets with drops: {sockets_with_drops} sockets ({total_socket_drops} socket drops)")
        if max_rx_queue >= warn_queue_bytes:
            issues.append(f"UDP socket rx_queue elevated: {max_rx_queue / (1024*1024):.2f} MB")

    top_rx_sockets = sorted(
        all_sockets,
        key=lambda x: x["rx_queue_bytes"],
        reverse=True,
    )[:5]

    top_drop_sockets = sorted(
        [s for s in all_sockets if s["drops"] > 0],
        key=lambda x: x["drops"],
        reverse=True,
    )[:5]

    return {
        "timestamp": now,
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "total_sockets": total_sockets,
            "ipv4_sockets": len(v4_sockets),
            "ipv6_sockets": len(v6_sockets),
            "total_socket_drops": total_socket_drops,
            "sockets_with_drops": sockets_with_drops,
            "total_rx_queue_bytes": total_rx_queue,
            "total_tx_queue_bytes": total_tx_queue,
            "max_rx_queue_bytes": max_rx_queue,
            "issues": issues,
        },
        "snmp_udp": {
            "in_datagrams": in_datagrams,
            "out_datagrams": out_datagrams,
            "in_errors": in_errors,
            "rcvbuf_errors": rcvbuf_errors,
            "sndbuf_errors": sndbuf_errors,
            "in_csum_errors": csum_errors,
            "mem_errors": mem_errors,
            "no_ports": no_ports,
            "rcvbuf_error_ratio_pct": round(rcvbuf_error_ratio, 4),
            "in_error_ratio_pct": round(in_error_ratio, 4),
        },
        "sysctl": {
            "udp_mem_pages": udp_mem,
            "udp_rmem_min_bytes": udp_rmem_min,
            "udp_wmem_min_bytes": udp_wmem_min,
        },
        "top_rx_sockets": top_rx_sockets,
        "top_drop_sockets": top_drop_sockets,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Host Network UDP Datagram Buffer & Socket Drop Guard (Pattern 215)"
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    parser.add_argument("--warn-rcvbuf-ratio", type=float, default=0.05, help="Warn ratio for RcvbufErrors / InDatagrams pct (default: 0.05)")
    parser.add_argument("--crit-rcvbuf-ratio", type=float, default=1.0, help="Crit ratio for RcvbufErrors / InDatagrams pct (default: 1.0)")
    parser.add_argument("--warn-queue-bytes", type=int, default=1048576, help="Warn threshold for rx_queue bytes (default: 1048576)")
    parser.add_argument("--crit-queue-bytes", type=int, default=8388608, help="Crit threshold for rx_queue bytes (default: 8388608)")
    parser.add_argument("--proc-udp", type=str, default="/proc/net/udp", help="Path to /proc/net/udp")
    parser.add_argument("--proc-udp6", type=str, default="/proc/net/udp6", help="Path to /proc/net/udp6")
    parser.add_argument("--proc-snmp", type=str, default="/proc/net/snmp", help="Path to /proc/net/snmp")
    parser.add_argument("--sysctl-dir", type=str, default="/proc/sys/net/ipv4", help="Path to /proc/sys/net/ipv4")

    args = parser.parse_args()

    report = audit_udp(
        proc_udp_path=args.proc_udp,
        proc_udp6_path=args.proc_udp6,
        proc_snmp_path=args.proc_snmp,
        sysctl_dir=args.sysctl_dir,
        warn_rcvbuf_ratio=args.warn_rcvbuf_ratio,
        crit_rcvbuf_ratio=args.crit_rcvbuf_ratio,
        warn_queue_bytes=args.warn_queue_bytes,
        crit_queue_bytes=args.crit_queue_bytes,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        sn = report["snmp_udp"]
        print(f"[{s['status']}] UDP Sockets: {s['total_sockets']} (v4: {s['ipv4_sockets']}, v6: {s['ipv6_sockets']}) | In: {sn['in_datagrams']:,} | Out: {sn['out_datagrams']:,}")
        print(f"  RcvbufErrors: {sn['rcvbuf_errors']:,} ({sn['rcvbuf_error_ratio_pct']}%) | SndbufErrors: {sn['sndbuf_errors']} | CsumErrors: {sn['in_csum_errors']} | MemErrors: {sn['mem_errors']}")
        print(f"  Socket Drops: {s['total_socket_drops']} | Max RX Queue: {s['max_rx_queue_bytes']} B | Total RX Queue: {s['total_rx_queue_bytes']} B")
        if s["issues"]:
            print("  Issues:")
            for issue in s["issues"]:
                print(f"    - {issue}")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
