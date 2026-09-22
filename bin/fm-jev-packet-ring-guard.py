#!/usr/bin/env python3
"""
bin/fm-jev-packet-ring-guard.py - Host Network Raw Packet Socket (AF_PACKET) Ring Buffer & Ethertype Filter Guard (Pattern 218)

Audits Linux kernel raw packet sockets (AF_PACKET) and mmap ring buffer queues:
  - /proc/net/packet (sk, RefCnt, Type, Proto ethertype, Iface index, R ring active, Rmem queued bytes, User UID, Inode)
  - Resolves ethertypes: ETH_P_ALL (0003, wildcard capture), ETH_P_IP (0800), ETH_P_ARP (0806), ETH_P_IPV6 (86dd), ETH_P_PAE (888e)

Detects rogue promiscuous packet capture (ETH_P_ALL), unconsumed packet socket buffer accumulation
(Rmem memory leaks from unresponsive tcpdump, sniffers, or CNI sidecars), and ring buffer exhaustion
across multi-agent test environments, container virtual interfaces, and host NICs.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when procfs is missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Optional


ETHERTYPE_MAP: Dict[str, str] = {
    "0003": "ETH_P_ALL (Wildcard Capture)",
    "0800": "ETH_P_IP (IPv4)",
    "0806": "ETH_P_ARP (Address Resolution)",
    "86dd": "ETH_P_IPV6 (IPv6)",
    "888e": "ETH_P_PAE (802.1X EAPOL)",
    "890d": "ETH_P_80211_RAW (802.11 Wireless)",
}


def parse_proc_net_packet(path: str = "/proc/net/packet") -> List[Dict[str, Any]]:
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
        if not parts or parts[0] == "sk":
            continue
        if len(parts) >= 9:
            try:
                sk = parts[0]
                refcnt = int(parts[1])
                sock_type = int(parts[2])
                proto_raw = parts[3].lower().zfill(4)
                iface_idx = int(parts[4])
                has_ring = int(parts[5])
                rmem = int(parts[6])
                user_uid = int(parts[7])
                inode = int(parts[8])

                proto_desc = ETHERTYPE_MAP.get(proto_raw, f"0x{proto_raw}")

                sockets.append({
                    "sk": sk,
                    "refcnt": refcnt,
                    "type": sock_type,
                    "proto_hex": proto_raw,
                    "proto_desc": proto_desc,
                    "iface_idx": iface_idx,
                    "has_ring": has_ring == 1,
                    "rmem_bytes": rmem,
                    "uid": user_uid,
                    "inode": inode,
                })
            except (ValueError, IndexError):
                continue

    return sockets


def audit_packet_sockets(
    proc_packet_path: str = "/proc/net/packet",
    warn_rmem_bytes: int = 10 * 1024 * 1024,
    crit_rmem_bytes: int = 50 * 1024 * 1024,
    warn_sockets: int = 100,
    crit_sockets: int = 500,
) -> Dict[str, Any]:
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    sockets = parse_proc_net_packet(proc_packet_path)

    total_sockets = len(sockets)
    total_rmem = sum(s["rmem_bytes"] for s in sockets)
    max_rmem = max((s["rmem_bytes"] for s in sockets), default=0)
    sockets_with_rmem = sum(1 for s in sockets if s["rmem_bytes"] > 0)

    ring_sockets = sum(1 for s in sockets if s["has_ring"])
    promisc_all = sum(1 for s in sockets if s["proto_hex"] == "0003")

    proto_counts: Dict[str, int] = {}
    uid_counts: Dict[str, int] = {}

    for s in sockets:
        p = s["proto_desc"]
        proto_counts[p] = proto_counts.get(p, 0) + 1
        u = str(s["uid"])
        uid_counts[u] = uid_counts.get(u, 0) + 1

    issues: List[str] = []
    status = "HEALTHY"

    if total_rmem >= crit_rmem_bytes:
        status = "CRITICAL"
        issues.append(f"Raw packet socket memory critical: {total_rmem / (1024*1024):.2f} MB (>= {crit_rmem_bytes / (1024*1024):.1f} MB)")
    elif total_rmem >= warn_rmem_bytes:
        status = "WARNING"
        issues.append(f"Raw packet socket memory elevated: {total_rmem / (1024*1024):.2f} MB")

    if total_sockets >= crit_sockets:
        status = "CRITICAL"
        issues.append(f"Raw packet socket proliferation critical: {total_sockets} sockets (>= {crit_sockets})")
    elif total_sockets >= warn_sockets and status != "CRITICAL":
        status = "WARNING"
        issues.append(f"Raw packet socket proliferation elevated: {total_sockets} sockets (>= {warn_sockets})")

    if promisc_all > 10 and status != "CRITICAL":
        status = "WARNING"
        issues.append(f"Excessive wildcard packet sniffing sockets (ETH_P_ALL): {promisc_all} sockets")

    top_rmem_sockets = sorted(
        sockets,
        key=lambda x: x["rmem_bytes"],
        reverse=True,
    )[:5]

    return {
        "timestamp": now,
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "total_packet_sockets": total_sockets,
            "ring_buffer_sockets": ring_sockets,
            "promiscuous_all_sockets": promisc_all,
            "total_rmem_bytes": total_rmem,
            "max_rmem_bytes": max_rmem,
            "sockets_with_rmem": sockets_with_rmem,
            "issues": issues,
        },
        "ethertypes": proto_counts,
        "uids": uid_counts,
        "top_rmem_sockets": top_rmem_sockets,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Host Network Raw Packet Socket Ring Buffer & Ethertype Filter Guard (Pattern 218)"
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    parser.add_argument("--proc-packet", type=str, default="/proc/net/packet", help="Path to /proc/net/packet")
    parser.add_argument("--warn-rmem", type=int, default=10 * 1024 * 1024, help="Warning threshold for rmem bytes")
    parser.add_argument("--crit-rmem", type=int, default=50 * 1024 * 1024, help="Critical threshold for rmem bytes")
    parser.add_argument("--warn-sockets", type=int, default=100, help="Warning threshold for socket count")
    parser.add_argument("--crit-sockets", type=int, default=500, help="Critical threshold for socket count")

    args = parser.parse_args()

    report = audit_packet_sockets(
        proc_packet_path=args.proc_packet,
        warn_rmem_bytes=args.warn_rmem,
        crit_rmem_bytes=args.crit_rmem,
        warn_sockets=args.warn_sockets,
        crit_sockets=args.crit_sockets,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"[{s['status']}] AF_PACKET Sockets: {s['total_packet_sockets']} | Ring Mmap: {s['ring_buffer_sockets']} | Wildcard (ALL): {s['promiscuous_all_sockets']} | Queued Rmem: {s['total_rmem_bytes']} B")
        print("  Ethertype Distribution:")
        for proto, count in report["ethertypes"].items():
            print(f"    - {proto:<35}: {count} sockets")
        if s["issues"]:
            print("  Issues:")
            for issue in s["issues"]:
                print(f"    - {issue}")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
