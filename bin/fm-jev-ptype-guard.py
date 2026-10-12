#!/usr/bin/env python3
"""
bin/fm-jev-ptype-guard.py - Host Network Kernel Packet Type Handler (ptype) & Ingress Dispatch Hook Guard (Pattern 220)

Audits Linux kernel packet type protocol handler dispatch tables:
  - /proc/net/ptype (Type protocol ethertype, Device attachment, Function dispatch symbol)
  - Distinguishes global vs per-device ingress packet taps
  - Resolves standard ethertypes:
      * ALL: Wildcard / Promiscuous Ingress Packet Tap (ptype_all)
      * 0800: IPv4 (ETH_P_IP -> ip_rcv)
      * 86dd: IPv6 (ETH_P_IPV6 -> ipv6_rcv)
      * 0806: ARP (ETH_P_ARP -> arp_rcv)
      * 888e: 802.1X EAPOL (ETH_P_PAE -> packet_rcv)
      * 0004: 802.2 LLC (ETH_P_802_2 -> llc_rcv)
      * 00fa: MCTP (ETH_P_MCTP -> mctp_pkttype_receive)

Detects rogue packet sniffing hooks, unauthorized promiscuous taps (ptype_all),
and handler bloat that forces redundant skb_clone copies and spikes NAPI softirq latency
across multi-agent test environments, container virtual bridges, and host gigabit NICs.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when /proc/net/ptype is missing or restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Optional


ETHERTYPE_MAP: Dict[str, str] = {
    "ALL": "ETH_P_ALL (Wildcard / Promiscuous Tap)",
    "0800": "ETH_P_IP (IPv4)",
    "86dd": "ETH_P_IPV6 (IPv6)",
    "0806": "ETH_P_ARP (Address Resolution)",
    "888e": "ETH_P_PAE (802.1X EAPOL)",
    "0004": "ETH_P_802_2 (802.2 LLC)",
    "00fa": "ETH_P_MCTP (Management Component Transport)",
    "890d": "ETH_P_80211_RAW (802.11 Wireless)",
}


def parse_proc_net_ptype(path: str = "/proc/net/ptype") -> List[Dict[str, Any]]:
    handlers: List[Dict[str, Any]] = []
    if not os.path.exists(path):
        return handlers

    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception:
        return handlers

    if not lines:
        return handlers

    for line in lines[1:]:
        if not line.strip():
            continue
        ptype_raw = line[:5].strip()
        dev_raw = line[5:14].strip()
        func_raw = line[14:].strip()

        dev = dev_raw if dev_raw else "<global>"
        ptype_key = ptype_raw.lower() if ptype_raw != "ALL" else "ALL"
        desc = ETHERTYPE_MAP.get(ptype_raw, ETHERTYPE_MAP.get(ptype_key, f"0x{ptype_raw}"))

        handlers.append({
            "type_raw": ptype_raw,
            "type_desc": desc,
            "is_wildcard": ptype_raw == "ALL",
            "device": dev,
            "is_global": dev == "<global>",
            "function": func_raw,
        })

    return handlers


def audit_ptype(
    proc_ptype_path: str = "/proc/net/ptype",
    warn_wildcard: int = 5,
    crit_wildcard: int = 15,
    warn_total: int = 25,
    crit_total: int = 60,
) -> Dict[str, Any]:
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    handlers = parse_proc_net_ptype(proc_ptype_path)

    total_handlers = len(handlers)
    wildcard_handlers = sum(1 for h in handlers if h["is_wildcard"])
    global_handlers = sum(1 for h in handlers if h["is_global"])
    device_specific_handlers = total_handlers - global_handlers

    handlers_by_proto: Dict[str, int] = {}
    handlers_by_device: Dict[str, int] = {}

    for h in handlers:
        p = h["type_desc"]
        handlers_by_proto[p] = handlers_by_proto.get(p, 0) + 1
        d = h["device"]
        handlers_by_device[d] = handlers_by_device.get(d, 0) + 1

    issues: List[str] = []
    status = "HEALTHY"

    if wildcard_handlers >= crit_wildcard:
        status = "CRITICAL"
        issues.append(
            f"Excessive wildcard packet taps (ptype_all) critical: {wildcard_handlers} handlers (>= {crit_wildcard})"
        )
    elif wildcard_handlers >= warn_wildcard:
        status = "WARNING"
        issues.append(
            f"Elevated wildcard packet taps (ptype_all): {wildcard_handlers} handlers (>= {warn_wildcard})"
        )

    if total_handlers >= crit_total and status != "CRITICAL":
        status = "CRITICAL"
        issues.append(f"Total packet handler table size critical: {total_handlers} handlers (>= {crit_total})")
    elif total_handlers >= warn_total and status == "HEALTHY":
        status = "WARNING"
        issues.append(f"Total packet handler table size elevated: {total_handlers} handlers (>= {warn_total})")

    return {
        "timestamp": now,
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "total_handlers": total_handlers,
            "wildcard_handlers": wildcard_handlers,
            "global_handlers": global_handlers,
            "device_specific_handlers": device_specific_handlers,
            "issues": issues,
        },
        "handlers": handlers,
        "by_protocol": handlers_by_proto,
        "by_device": handlers_by_device,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Host Network Kernel Packet Type Handler (ptype) Guard (Pattern 220)"
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    parser.add_argument("--proc-ptype", type=str, default="/proc/net/ptype", help="Path to /proc/net/ptype")
    parser.add_argument(
        "--warn-wildcard",
        type=int,
        default=5,
        help="Warning threshold for wildcard (ptype_all) handlers (default 5)",
    )
    parser.add_argument(
        "--crit-wildcard",
        type=int,
        default=15,
        help="Critical threshold for wildcard (ptype_all) handlers (default 15)",
    )
    parser.add_argument(
        "--warn-total",
        type=int,
        default=25,
        help="Warning threshold for total packet handlers (default 25)",
    )
    parser.add_argument(
        "--crit-total",
        type=int,
        default=60,
        help="Critical threshold for total packet handlers (default 60)",
    )

    args = parser.parse_args()

    report = audit_ptype(
        proc_ptype_path=args.proc_ptype,
        warn_wildcard=args.warn_wildcard,
        crit_wildcard=args.crit_wildcard,
        warn_total=args.warn_total,
        crit_total=args.crit_total,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(
            f"[{s['status']}] Packet Protocol Handlers: {s['total_handlers']} | Wildcard Taps (ALL): {s['wildcard_handlers']} | Global: {s['global_handlers']} | Device-Specific: {s['device_specific_handlers']}"
        )
        print("  Registered Handlers:")
        for h in report["handlers"]:
            print(f"    - {h['type_raw']:<5} ({h['type_desc']}): dev={h['device']} -> {h['function']}")
        if s["issues"]:
            print("  Issues:")
            for issue in s["issues"]:
                print(f"    - {issue}")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
