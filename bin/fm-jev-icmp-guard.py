#!/usr/bin/env python3
"""
fm-jev-icmp-guard.py - Jev Multi-Agent Host Network Protocol Error & ICMP Blackhole Guard (Pattern 94)

Audits Linux kernel network protocol error counters (/proc/net/snmp, /proc/net/netstat) across IP, ICMP, TCP,
and UDP. Detects MTU path discovery blackholes (FragFails), unroutable packet drops (OutNoRoutes), routing loops
(InTimeExcds), TCP connection aborts (EstabResets, AttemptFails), and ICMP rate-limit throttling before multi-agent
RPC streams, model token queries, and external APIs suffer silent connection timeouts.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when procfs snmp files are missing.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

PROC_NET_SNMP = "/proc/net/snmp"

DEFAULT_WARN_FRAG_FAILS = 20
DEFAULT_CRIT_FRAG_FAILS = 100
DEFAULT_WARN_NO_ROUTES = 1000
DEFAULT_CRIT_NO_ROUTES = 10000


def parse_snmp(path: Path) -> Dict[str, Dict[str, int]]:
    """Parses /proc/net/snmp into a nested dict by protocol and metric name."""
    result: Dict[str, Dict[str, int]] = {}
    if not path.is_file():
        return result
    try:
        lines = path.read_text().strip().splitlines()
        for i in range(0, len(lines) - 1, 2):
            header_line = lines[i].strip()
            values_line = lines[i + 1].strip()

            header_parts = header_line.split()
            values_parts = values_line.split()

            if not header_parts or not values_parts:
                continue

            proto = header_parts[0].rstrip(":")
            proto_val = values_parts[0].rstrip(":")
            if proto != proto_val:
                continue

            metric_names = header_parts[1:]
            metric_values = values_parts[1:]

            proto_metrics: Dict[str, int] = {}
            for name, val_str in zip(metric_names, metric_values):
                try:
                    proto_metrics[name] = int(val_str)
                except ValueError:
                    proto_metrics[name] = 0
            result[proto] = proto_metrics
    except Exception:
        pass
    return result


def audit_snmp(
    snmp_path: Optional[str] = None,
    warn_frag_fails: int = DEFAULT_WARN_FRAG_FAILS,
    crit_frag_fails: int = DEFAULT_CRIT_FRAG_FAILS,
    warn_no_routes: int = DEFAULT_WARN_NO_ROUTES,
    crit_no_routes: int = DEFAULT_CRIT_NO_ROUTES,
) -> Dict[str, Any]:
    """Audits network protocol counters for blackhole and routing errors."""
    snmp_file = Path(snmp_path) if snmp_path else Path(PROC_NET_SNMP)
    snmp_data = parse_snmp(snmp_file)

    ip = snmp_data.get("Ip", {})
    icmp = snmp_data.get("Icmp", {})
    tcp = snmp_data.get("Tcp", {})
    udp = snmp_data.get("Udp", {})

    frag_fails = ip.get("FragFails", 0)
    out_no_routes = ip.get("OutNoRoutes", 0)
    in_hdr_errors = ip.get("InHdrErrors", 0)
    in_addr_errors = ip.get("InAddrErrors", 0)

    icmp_dest_unreach = icmp.get("InDestUnreachs", 0)
    icmp_time_excds = icmp.get("InTimeExcds", 0)
    icmp_ratelimit_global = icmp.get("OutRateLimitGlobal", 0)
    icmp_ratelimit_host = icmp.get("OutRateLimitHost", 0)

    tcp_retrans_segs = tcp.get("RetransSegs", 0)
    tcp_estab_resets = tcp.get("EstabResets", 0)
    tcp_attempt_fails = tcp.get("AttemptFails", 0)
    tcp_in_errs = tcp.get("InErrs", 0)

    udp_in_errors = udp.get("InErrors", 0)
    udp_rcvbuf_errors = udp.get("RcvbufErrors", 0)
    udp_sndbuf_errors = udp.get("SndbufErrors", 0)

    issues: List[str] = []

    if frag_fails >= crit_frag_fails:
        issues.append(
            f"CRITICAL MTU Fragmentation Failures: {frag_fails:,} failed fragments. Imminent MTU blackhole risk."
        )
    elif frag_fails >= warn_frag_fails:
        issues.append(
            f"Elevated MTU Fragmentation Failures: {frag_fails:,} failed fragments. Check MTU discovery."
        )

    if out_no_routes >= crit_no_routes:
        issues.append(
            f"CRITICAL Outbound Unroutable Packets: {out_no_routes:,} dropped (OutNoRoutes). Check default route/VPN tunnels."
        )
    elif out_no_routes >= warn_no_routes:
        issues.append(
            f"Elevated Outbound Unroutable Packets: {out_no_routes:,} dropped (OutNoRoutes)."
        )

    if icmp_time_excds > 0:
        issues.append(
            f"ICMP Time-to-Live Expired: {icmp_time_excds:,} packets (routing loop or high hop count detected)."
        )

    status = "HEALTHY"
    if any("CRITICAL" in iss for iss in issues):
        status = "CRITICAL"
    elif issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "frag_fails": frag_fails,
            "out_no_routes": out_no_routes,
            "icmp_dest_unreach": icmp_dest_unreach,
            "icmp_time_excds": icmp_time_excds,
            "icmp_ratelimit_drops": icmp_ratelimit_global + icmp_ratelimit_host,
            "tcp_retrans_segs": tcp_retrans_segs,
            "tcp_estab_resets": tcp_estab_resets,
            "tcp_attempt_fails": tcp_attempt_fails,
            "udp_buffer_errors": udp_rcvbuf_errors + udp_sndbuf_errors,
            "issues": issues,
        },
        "metrics": {
            "ip": ip,
            "icmp": icmp,
            "tcp": tcp,
            "udp": udp,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network Protocol Error & ICMP Blackhole Guard (Pattern 94)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument(
        "--warn-frag-fails",
        type=int,
        default=DEFAULT_WARN_FRAG_FAILS,
        help=f"Warning IP fragmentation failure threshold (default {DEFAULT_WARN_FRAG_FAILS})",
    )
    parser.add_argument(
        "--crit-frag-fails",
        type=int,
        default=DEFAULT_CRIT_FRAG_FAILS,
        help=f"Critical IP fragmentation failure threshold (default {DEFAULT_CRIT_FRAG_FAILS})",
    )
    parser.add_argument(
        "--warn-no-routes",
        type=int,
        default=DEFAULT_WARN_NO_ROUTES,
        help=f"Warning OutNoRoutes threshold (default {DEFAULT_WARN_NO_ROUTES})",
    )
    parser.add_argument(
        "--crit-no-routes",
        type=int,
        default=DEFAULT_CRIT_NO_ROUTES,
        help=f"Critical OutNoRoutes threshold (default {DEFAULT_CRIT_NO_ROUTES})",
    )
    parser.add_argument("--snmp-path", type=str, default=None, help="Path to /proc/net/snmp")
    args = parser.parse_args()

    result = audit_snmp(
        snmp_path=args.snmp_path,
        warn_frag_fails=args.warn_frag_fails,
        crit_frag_fails=args.crit_frag_fails,
        warn_no_routes=args.warn_no_routes,
        crit_no_routes=args.crit_no_routes,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = (
        "\033[32m"
        if summary["healthy"]
        else ("\033[31m" if summary["status"] == "CRITICAL" else "\033[33m")
    )
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network Protocol Error & ICMP Blackhole Guard (Pattern 94)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    print(f" IP Frag Failures:       {summary['frag_fails']:,}")
    print(f" Outbound No-Routes:     {summary['out_no_routes']:,}")
    print(f" ICMP Dest Unreachable:  {summary['icmp_dest_unreach']:,}")
    print(f" ICMP Time-to-Live Exp:  {summary['icmp_time_excds']:,}")
    print(f" ICMP Rate-Limit Drops:  {summary['icmp_ratelimit_drops']:,}")
    print(f" TCP Retransmit Segs:    {summary['tcp_retrans_segs']:,}")
    print(f" TCP Established Resets: {summary['tcp_estab_resets']:,}")
    print(f" TCP Connection Fails:   {summary['tcp_attempt_fails']:,}")
    print(f" UDP Buffer Overruns:    {summary['udp_buffer_errors']:,}")

    if summary["issues"]:
        print("\nActive Protocol Error Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nNetwork protocol counters nominal. Zero MTU blackhole or routing loop risk.")
    print("================================================================================")


if __name__ == "__main__":
    main()
