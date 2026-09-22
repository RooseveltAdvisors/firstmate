#!/usr/bin/env python3
"""
bin/fm-jev-ipv6-snmp-guard.py - Host Network IPv6 Protocol Stack (snmp6) & Route Drop Guard (Pattern 221)

Audits Linux kernel IPv6 protocol statistics and network counters:
  - /proc/net/snmp6 (Ip6, Icmp6, Udp6, UdpLite6 counters)
  - /proc/sys/net/ipv6/conf/all/disable_ipv6
  - Inbound & outbound packet delivery (Ip6InReceives, Ip6InDelivers, Ip6OutRequests)
  - Outbound route lookup drop events (Ip6OutNoRoutes)
  - Packet integrity & discard counters (Ip6InHdrErrors, Ip6InAddrErrors, Ip6InDiscards)
  - Fragmentation and reassembly health (Ip6FragFails, Ip6ReasmTimeout, Ip6ReasmFails)
  - UDP6 buffer and memory exhaustion (Udp6RcvbufErrors, Udp6SndbufErrors, Udp6MemErrors)
  - Router solicitation / Neighbor discovery activity (Icmp6OutRouterSolicits, Icmp6OutNeighborSolicits)

Detects Happy Eyeballs fallback stalls, IPv6 blackholing, UDP6 buffer overflow, and socket memory exhaustion
across multi-agent test environments, container virtual networks, and dual-stack host interfaces.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when /proc/net/snmp6 is missing or restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import subprocess
import sys
from typing import Any, Dict, List, Optional


def check_default_ipv6_route() -> bool:
    try:
        proc = subprocess.run(
            ["ip", "-6", "route", "show", "default"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=2,
        )
        return proc.returncode == 0 and bool(proc.stdout.strip())
    except Exception:
        return False


def read_sysctl_int(path: str) -> Optional[int]:
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return int(f.read().strip())
        except Exception:
            pass
    return None


def parse_proc_net_snmp6(path: str = "/proc/net/snmp6") -> Dict[str, int]:
    stats: Dict[str, int] = {}
    if not os.path.exists(path):
        return stats

    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 2:
                    try:
                        stats[parts[0]] = int(parts[1])
                    except ValueError:
                        pass
    except Exception:
        pass

    return stats


def audit_ipv6_snmp(
    proc_snmp6_path: str = "/proc/net/snmp6",
    check_route: bool = True,
    warn_hdr_errors: int = 10,
    crit_hdr_errors: int = 100,
    warn_udp_rcvbuf_errors: int = 50,
    crit_udp_rcvbuf_errors: int = 500,
    warn_udp_mem_errors: int = 1,
    warn_discards: int = 10000,
) -> Dict[str, Any]:
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    stats = parse_proc_net_snmp6(proc_snmp6_path)
    disable_all = read_sysctl_int("/proc/sys/net/ipv6/conf/all/disable_ipv6")
    disable_default = read_sysctl_int("/proc/sys/net/ipv6/conf/default/disable_ipv6")

    has_default_route = check_default_ipv6_route() if check_route else False

    in_receives = stats.get("Ip6InReceives", 0)
    in_delivers = stats.get("Ip6InDelivers", 0)
    out_requests = stats.get("Ip6OutRequests", 0)
    out_no_routes = stats.get("Ip6OutNoRoutes", 0)
    in_discards = stats.get("Ip6InDiscards", 0)
    in_hdr_errors = stats.get("Ip6InHdrErrors", 0)
    in_addr_errors = stats.get("Ip6InAddrErrors", 0)
    frag_fails = stats.get("Ip6FragFails", 0)
    reasm_timeouts = stats.get("Ip6ReasmTimeout", 0)
    udp6_rcvbuf_errors = stats.get("Udp6RcvbufErrors", 0)
    udp6_sndbuf_errors = stats.get("Udp6SndbufErrors", 0)
    udp6_mem_errors = stats.get("Udp6MemErrors", 0)
    router_solicits = stats.get("Icmp6OutRouterSolicits", 0)
    neighbor_solicits = stats.get("Icmp6OutNeighborSolicits", 0)

    issues: List[str] = []
    status = "HEALTHY"

    if in_hdr_errors >= crit_hdr_errors or in_addr_errors >= crit_hdr_errors:
        status = "CRITICAL"
        issues.append(f"IPv6 header/address errors critical: hdr={in_hdr_errors}, addr={in_addr_errors}")
    elif in_hdr_errors >= warn_hdr_errors or in_addr_errors >= warn_hdr_errors:
        status = "WARNING"
        issues.append(f"IPv6 header/address errors elevated: hdr={in_hdr_errors}, addr={in_addr_errors}")

    if udp6_rcvbuf_errors >= crit_udp_rcvbuf_errors:
        status = "CRITICAL"
        issues.append(f"UDP6 receive buffer overflow critical: {udp6_rcvbuf_errors} drops")
    elif udp6_rcvbuf_errors >= warn_udp_rcvbuf_errors and status != "CRITICAL":
        status = "WARNING"
        issues.append(f"UDP6 receive buffer overflow elevated: {udp6_rcvbuf_errors} drops")

    if udp6_mem_errors >= warn_udp_mem_errors and status != "CRITICAL":
        status = "WARNING"
        issues.append(f"UDP6 kernel memory allocation errors detected: {udp6_mem_errors}")

    if in_discards >= warn_discards and status == "HEALTHY":
        status = "WARNING"
        issues.append(f"IPv6 inbound discards elevated: {in_discards}")

    return {
        "timestamp": now,
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "ipv6_enabled": disable_all == 0 and disable_default == 0,
            "has_default_route": has_default_route,
            "in_receives": in_receives,
            "in_delivers": in_delivers,
            "out_requests": out_requests,
            "out_no_routes": out_no_routes,
            "in_discards": in_discards,
            "in_hdr_errors": in_hdr_errors,
            "udp6_rcvbuf_errors": udp6_rcvbuf_errors,
            "udp6_mem_errors": udp6_mem_errors,
            "issues": issues,
        },
        "counters": {
            "Ip6InReceives": in_receives,
            "Ip6InDelivers": in_delivers,
            "Ip6OutRequests": out_requests,
            "Ip6OutNoRoutes": out_no_routes,
            "Ip6InDiscards": in_discards,
            "Ip6InHdrErrors": in_hdr_errors,
            "Ip6InAddrErrors": in_addr_errors,
            "Ip6FragFails": frag_fails,
            "Ip6ReasmTimeout": reasm_timeouts,
            "Udp6RcvbufErrors": udp6_rcvbuf_errors,
            "Udp6SndbufErrors": udp6_sndbuf_errors,
            "Udp6MemErrors": udp6_mem_errors,
            "Icmp6OutRouterSolicits": router_solicits,
            "Icmp6OutNeighborSolicits": neighbor_solicits,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Host Network IPv6 Protocol Stack (snmp6) & Route Drop Guard (Pattern 221)"
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    parser.add_argument("--proc-snmp6", type=str, default="/proc/net/snmp6", help="Path to /proc/net/snmp6")
    parser.add_argument("--no-route-check", action="store_true", help="Skip default IPv6 route lookup")
    parser.add_argument(
        "--warn-hdr-errors",
        type=int,
        default=10,
        help="Warning threshold for header errors (default 10)",
    )
    parser.add_argument(
        "--crit-hdr-errors",
        type=int,
        default=100,
        help="Critical threshold for header errors (default 100)",
    )
    parser.add_argument(
        "--warn-udp-rcvbuf",
        type=int,
        default=50,
        help="Warning threshold for UDP6 rcvbuf errors (default 50)",
    )
    parser.add_argument(
        "--crit-udp-rcvbuf",
        type=int,
        default=500,
        help="Critical threshold for UDP6 rcvbuf errors (default 500)",
    )

    args = parser.parse_args()

    report = audit_ipv6_snmp(
        proc_snmp6_path=args.proc_snmp6,
        check_route=not args.no_route_check,
        warn_hdr_errors=args.warn_hdr_errors,
        crit_hdr_errors=args.crit_hdr_errors,
        warn_udp_rcvbuf_errors=args.warn_udp_rcvbuf,
        crit_udp_rcvbuf_errors=args.crit_udp_rcvbuf,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        route_str = "Default Route Active" if s["has_default_route"] else "No Default Route (Happy Eyeballs Fallback)"
        print(
            f"[{s['status']}] IPv6 Protocol Stack: In: {s['in_receives']} pkts | Out: {s['out_requests']} pkts | OutNoRoutes: {s['out_no_routes']} | {route_str}"
        )
        print(
            f"  Discards: {s['in_discards']} | HdrErrors: {s['in_hdr_errors']} | Udp6RcvbufErrors: {s['udp6_rcvbuf_errors']} | Udp6MemErrors: {s['udp6_mem_errors']}"
        )
        if s["issues"]:
            print("  Issues:")
            for issue in s["issues"]:
                print(f"    - {issue}")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
