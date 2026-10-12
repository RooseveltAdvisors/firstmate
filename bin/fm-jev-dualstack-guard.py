#!/usr/bin/env python3
"""
fm-jev-dualstack-guard.py - Jev Multi-Agent Host Network IPv4/IPv6 Dual-Stack Guard (Pattern 124)

Audits Linux IPv6 socket dual-stack binding policy (/proc/sys/net/ipv6/bindv6only),
global IPv6 enablement (/proc/sys/net/ipv6/conf/all/disable_ipv6), and SNMP6 routing/drop counters
from /proc/net/snmp6 (Ip6InReceives, Ip6InNoRoutes, Ip6InDiscards, Ip6OutDiscards).

Detects strict IPv6-only socket locking (bindv6only=1) that blocks IPv4-mapped connections on wildcard listeners,
IPv6 protocol stack disabling, and IPv6 routing discard spikes across multi-agent RPC and local web servers.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when IPv6 is disabled in kernel or procfs files missing.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

SYSCTL_BINDV6ONLY = "/proc/sys/net/ipv6/bindv6only"
SYSCTL_DISABLE_IPV6 = "/proc/sys/net/ipv6/conf/all/disable_ipv6"
PROC_SNMP6 = "/proc/net/snmp6"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def parse_snmp6(path: Path) -> Dict[str, int]:
    """Parses key-value metrics from /proc/net/snmp6."""
    if not path.is_file():
        return {}

    metrics: Dict[str, int] = {}
    try:
        lines = path.read_text().splitlines()
        for line in lines:
            parts = line.split()
            if len(parts) >= 2:
                try:
                    metrics[parts[0]] = int(parts[1])
                except ValueError:
                    continue
    except Exception:
        return {}

    return metrics


def audit_dualstack(
    bindv6only_file: Optional[str] = None,
    disable_ipv6_file: Optional[str] = None,
    snmp6_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host IPv4/IPv6 dual-stack socket policy and drop counters."""
    bindv6_p = Path(bindv6only_file or SYSCTL_BINDV6ONLY)
    disable_p = Path(disable_ipv6_file or SYSCTL_DISABLE_IPV6)
    snmp6_p = Path(snmp6_file or PROC_SNMP6)

    bindv6only = read_int_file(bindv6_p)
    if bindv6only is None:
        bindv6only = 0

    disable_ipv6 = read_int_file(disable_p)
    if disable_ipv6 is None:
        disable_ipv6 = 0

    snmp6 = parse_snmp6(snmp6_p)
    in_receives = snmp6.get("Ip6InReceives", 0)
    in_no_routes = snmp6.get("Ip6InNoRoutes", 0)
    in_discards = snmp6.get("Ip6InDiscards", 0)
    out_discards = snmp6.get("Ip6OutDiscards", 0)

    issues: List[str] = []
    healthy = True

    if bindv6only == 1:
        healthy = False
        issues.append("bindv6only is enabled (1). Dual-stack sockets cannot accept IPv4-mapped traffic on wildcard listeners.")

    if disable_ipv6 == 1:
        issues.append("IPv6 is globally disabled (conf/all/disable_ipv6 = 1). AF_INET6 socket creation will fail with EAFNOSUPPORT.")

    if in_no_routes > 1000:
        healthy = False
        issues.append(f"Elevated IPv6 no-route discards ({in_no_routes:,} packets). Missing IPv6 default gateway or route flapping.")

    if in_discards > 50000:
        healthy = False
        issues.append(f"Elevated IPv6 input packet discards ({in_discards:,} packets). Buffer exhaustion or malformed headers.")

    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "bindv6only": bindv6only,
            "disable_ipv6": disable_ipv6,
            "in_receives": in_receives,
            "in_no_routes": in_no_routes,
            "in_discards": in_discards,
            "out_discards": out_discards,
            "issues": issues,
        },
        "counters": {
            "in_receives": in_receives,
            "in_no_routes": in_no_routes,
            "in_discards": in_discards,
            "out_discards": out_discards,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network IPv4/IPv6 Dual-Stack Guard (Pattern 124)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--bindv6only-file", type=str, default=None, help="Path to bindv6only")
    parser.add_argument("--disable-ipv6-file", type=str, default=None, help="Path to disable_ipv6")
    parser.add_argument("--snmp6-file", type=str, default=None, help="Path to /proc/net/snmp6")
    args = parser.parse_args()

    result = audit_dualstack(
        bindv6only_file=args.bindv6only_file,
        disable_ipv6_file=args.disable_ipv6_file,
        snmp6_file=args.snmp6_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network IPv4/IPv6 Dual-Stack Guard (Pattern 124)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Dual-Stack Policy (bindv6only): {summary['bindv6only']} ({'Dual-Stack Default (IPv4-Mapped Allowed)' if summary['bindv6only'] == 0 else 'Strict IPv6 Only'})")
    print(f" Global IPv6 Status:            {'Enabled (0)' if summary['disable_ipv6'] == 0 else 'Disabled (1)'}")
    print(f" IPv6 Ingress Packets:          {summary['in_receives']:,}")
    print(f" IPv6 Ingress Discards:         {summary['in_discards']:,}")
    print(f" IPv6 Ingress No-Routes:        {summary['in_no_routes']:,}")
    print(f" IPv6 Egress Discards:          {summary['out_discards']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'IPv6 Dual-Stack Metric':<35} {'Count / Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'bindv6only':<35} {summary['bindv6only']:<15} {'Nominal' if summary['bindv6only'] == 0 else 'WARNING'}")
    print(f" {'disable_ipv6':<35} {summary['disable_ipv6']:<15} Nominal")
    print(f" {'IPv6 Ingress Packets':<35} {counters['in_receives']:<15} Nominal")
    print(f" {'IPv6 Ingress Discards':<35} {counters['in_discards']:<15} {'Nominal' if counters['in_discards'] <= 50000 else 'WARNING'}")
    print(f" {'IPv6 Ingress No-Routes':<35} {counters['in_no_routes']:<15} {'Nominal' if counters['in_no_routes'] <= 1000 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive IPv6 Dual-Stack Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host IPv4/IPv6 dual-stack socket parameters and SNMP6 counters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
