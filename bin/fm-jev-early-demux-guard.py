#!/usr/bin/env python3
"""
fm-jev-early-demux-guard.py - Jev Multi-Agent Host Network TCP/IP Early Demux Guard (Pattern 129)

Audits Linux kernel TCP and IP early demux optimization switches (/proc/sys/net/ipv4/tcp_early_demux,
/proc/sys/net/ipv4/ip_early_demux, /proc/sys/net/ipv4/udp_early_demux) and correlates against
IP delivery / discard counters from /proc/net/snmp.

In high-frequency multi-agent RPC and webhook delivery grids, early demux performs fast socket hash table
lookups directly at the IP layer for established connections, bypassing expensive Forwarding Information
Base (FIB) routing table traversals and reducing softirq packet processing latency by up to 30%.

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
from typing import Any, Dict, List, Optional

SYSCTL_IP_EARLY_DEMUX = "/proc/sys/net/ipv4/ip_early_demux"
SYSCTL_TCP_EARLY_DEMUX = "/proc/sys/net/ipv4/tcp_early_demux"
SYSCTL_UDP_EARLY_DEMUX = "/proc/sys/net/ipv4/udp_early_demux"

PROC_SNMP = "/proc/net/snmp"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def parse_proc_pairs(path: Path, section_name: str) -> Dict[str, int]:
    """Parses paired header/metric lines from /proc/net/snmp."""
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
        return {}

    return metrics


def audit_early_demux(
    ip_early_file: Optional[str] = None,
    tcp_early_file: Optional[str] = None,
    udp_early_file: Optional[str] = None,
    snmp_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host TCP/IP early demux parameters and IP ingress metrics."""
    ip_p = Path(ip_early_file or SYSCTL_IP_EARLY_DEMUX)
    tcp_p = Path(tcp_early_file or SYSCTL_TCP_EARLY_DEMUX)
    udp_p = Path(udp_early_file or SYSCTL_UDP_EARLY_DEMUX)
    snmp_p = Path(snmp_file or PROC_SNMP)

    ip_demux = read_int_file(ip_p)
    if ip_demux is None:
        ip_demux = 1

    tcp_demux = read_int_file(tcp_p)
    if tcp_demux is None:
        tcp_demux = 1

    udp_demux = read_int_file(udp_p)
    if udp_demux is None:
        udp_demux = 1

    ip_metrics = parse_proc_pairs(snmp_p, "Ip")
    in_receives = ip_metrics.get("InReceives", 0)
    in_delivers = ip_metrics.get("InDelivers", 0)
    forw_datagrams = ip_metrics.get("ForwDatagrams", 0)
    in_discards = ip_metrics.get("InDiscards", 0)
    in_hdr_errors = ip_metrics.get("InHdrErrors", 0)

    issues: List[str] = []
    healthy = True

    if ip_demux == 0:
        healthy = False
        issues.append("Global IP early demux is disabled (ip_early_demux = 0). Route lookup bypass disabled across all L4 protocols.")

    if tcp_demux == 0:
        healthy = False
        issues.append("TCP early demux is disabled (tcp_early_demux = 0). Incoming TCP segments must traverse full FIB routing table.")

    if in_discards > 50000:
        healthy = False
        issues.append(f"Elevated IP ingress discards ({in_discards:,} packets). Buffer saturation or checksum drop.")

    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "ip_early_demux": ip_demux,
            "tcp_early_demux": tcp_demux,
            "udp_early_demux": udp_demux,
            "in_receives": in_receives,
            "in_delivers": in_delivers,
            "in_discards": in_discards,
            "issues": issues,
        },
        "counters": {
            "in_receives": in_receives,
            "in_delivers": in_delivers,
            "forw_datagrams": forw_datagrams,
            "in_discards": in_discards,
            "in_hdr_errors": in_hdr_errors,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP/IP Early Demux Guard (Pattern 129)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--ip-early-file", type=str, default=None, help="Path to ip_early_demux")
    parser.add_argument("--tcp-early-file", type=str, default=None, help="Path to tcp_early_demux")
    parser.add_argument("--udp-early-file", type=str, default=None, help="Path to udp_early_demux")
    parser.add_argument("--snmp-file", type=str, default=None, help="Path to /proc/net/snmp")
    args = parser.parse_args()

    result = audit_early_demux(
        ip_early_file=args.ip_early_file,
        tcp_early_file=args.tcp_early_file,
        udp_early_file=args.udp_early_file,
        snmp_file=args.snmp_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP/IP Early Demux Guard (Pattern 129)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Global IP Early Demux:         {summary['ip_early_demux']} ({'Enabled (Routing Bypass Active)' if summary['ip_early_demux'] == 1 else 'Disabled'})")
    print(f" TCP Early Demux:               {summary['tcp_early_demux']} ({'Enabled (Fast Socket Demux)' if summary['tcp_early_demux'] == 1 else 'Disabled'})")
    print(f" UDP Early Demux:               {summary['udp_early_demux']} ({'Enabled' if summary['udp_early_demux'] == 1 else 'Disabled'})")
    print(f" Total Ingress Packets:         {counters['in_receives']:,}")
    print(f" Packets Delivered Locally:     {counters['in_delivers']:,}")
    print(f" Ingress Discards:              {counters['in_discards']:,}")
    print(f" Forwarded Datagrams:           {counters['forw_datagrams']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Early Demux / Route Metric':<35} {'Count / Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'ip_early_demux':<35} {summary['ip_early_demux']:<15} {'Nominal' if summary['ip_early_demux'] == 1 else 'WARNING'}")
    print(f" {'tcp_early_demux':<35} {summary['tcp_early_demux']:<15} {'Nominal' if summary['tcp_early_demux'] == 1 else 'WARNING'}")
    print(f" {'udp_early_demux':<35} {summary['udp_early_demux']:<15} {'Nominal' if summary['udp_early_demux'] == 1 else 'WARNING'}")
    print(f" {'Ingress Discards':<35} {counters['in_discards']:<15} {'Nominal' if counters['in_discards'] <= 50000 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive Early Demux Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP/IP early demux switches, socket bypass routes, and delivery counters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
