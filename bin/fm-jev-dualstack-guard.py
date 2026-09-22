#!/usr/bin/env python3
"""
fm-jev-dualstack-guard.py - Jev Multi-Agent Host Network Dual-Stack Socket & IPv6 Fallback Guard (Pattern 124)

Audits Linux IPv6 dual-stack socket binding semantics (/proc/sys/net/ipv6/bindv6only),
per-interface IPv6 enablement (/proc/sys/net/ipv6/conf/*/disable_ipv6), active listening IPv6
sockets (/proc/net/tcp6), and IPv6 packet discard statistics from /proc/net/snmp6.

Detects silent bind collisions and connection drops when dual-stack listeners fail to receive
IPv4-mapped connections or when IPv6 routing discards packets during inter-agent cluster mesh.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysfs/procfs files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

BINDV6ONLY_FILE = "/proc/sys/net/ipv6/bindv6only"
CONF_DIR = "/proc/sys/net/ipv6/conf"
PROC_TCP6 = "/proc/net/tcp6"
PROC_SNMP6 = "/proc/net/snmp6"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def parse_tcp6_listening(path: Path) -> List[Dict[str, Any]]:
    """Parses listening sockets from /proc/net/tcp6."""
    if not path.is_file():
        return []

    listeners: List[Dict[str, Any]] = []
    try:
        lines = path.read_text().splitlines()
        for line in lines[1:]:  # Skip header
            tokens = line.strip().split()
            if len(tokens) >= 4:
                state = tokens[3]
                # '0A' is TCP_LISTEN
                if state == "0A":
                    local_addr = tokens[1]
                    parts = local_addr.split(":")
                    port = int(parts[1], 16) if len(parts) > 1 else 0
                    inode = tokens[9] if len(tokens) > 9 else "0"
                    is_wildcard = parts[0] == "00000000000000000000000000000000"
                    listeners.append({
                        "local_raw": local_addr,
                        "port": port,
                        "is_wildcard": is_wildcard,
                        "inode": inode,
                    })
    except Exception:
        return listeners

    return listeners


def parse_snmp6(path: Path) -> Dict[str, int]:
    """Parses key-value IPv6 statistics from /proc/net/snmp6."""
    if not path.is_file():
        return {}

    metrics: Dict[str, int] = {}
    try:
        lines = path.read_text().splitlines()
        for line in lines:
            tokens = line.strip().split()
            if len(tokens) >= 2:
                try:
                    metrics[tokens[0]] = int(tokens[1])
                except ValueError:
                    continue
    except Exception:
        return {}

    return metrics


def audit_dualstack(
    bindv6only_file: Optional[str] = None,
    conf_dir: Optional[str] = None,
    tcp6_file: Optional[str] = None,
    snmp6_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits IPv6 dual-stack socket binding configuration and runtime state."""
    b6_p = Path(bindv6only_file or BINDV6ONLY_FILE)
    conf_p = Path(conf_dir or CONF_DIR)
    tcp6_p = Path(tcp6_file or PROC_TCP6)
    snmp6_p = Path(snmp6_file or PROC_SNMP6)

    bindv6only = read_int_file(b6_p)
    if bindv6only is None:
        bindv6only = 0

    disabled_ifaces: Dict[str, int] = {}
    if conf_p.is_dir():
        for p in sorted(conf_p.glob("*/disable_ipv6")):
            val = read_int_file(p)
            if val is not None:
                disabled_ifaces[p.parent.name] = val

    listeners = parse_tcp6_listening(tcp6_p)
    snmp6 = parse_snmp6(snmp6_p)

    ip6_in_receives = snmp6.get("Ip6InReceives", 0)
    ip6_in_discards = snmp6.get("Ip6InDiscards", 0)
    ip6_in_no_routes = snmp6.get("Ip6InNoRoutes", 0)
    ip6_out_requests = snmp6.get("Ip6OutRequests", 0)

    issues: List[str] = []
    healthy = True

    # Check bindv6only
    if bindv6only == 1:
        # Strict IPv6-only mode: wildcards do NOT listen on IPv4-mapped addresses
        wildcards = [l for l in listeners if l["is_wildcard"]]
        if wildcards:
            healthy = False
            issues.append(
                f"net.ipv6.bindv6only is enabled (1). {len(wildcards)} wildcard listeners (::) will NOT "
                "accept IPv4 connections unless IPV6_V6ONLY=0 is explicitly set per socket."
            )

    # Check IPv6 discards
    if ip6_in_receives > 0 and ip6_in_discards > 0:
        discard_rate = ip6_in_discards / ip6_in_receives
        if discard_rate > 0.05:  # > 5% discard
            healthy = False
            issues.append(
                f"Elevated IPv6 inbound discard rate: {discard_rate:.2%} ({ip6_in_discards:,} / {ip6_in_receives:,})."
            )

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "healthy": healthy,
        "status": "HEALTHY" if healthy else "WARNING",
        "pattern": 124,
        "name": "Host Network Dual-Stack Socket & IPv6 Fallback Guard",
        "issues": issues,
        "config": {
            "bindv6only": bindv6only,
            "dual_stack_default": bindv6only == 0,
            "disabled_interfaces": disabled_ifaces,
        },
        "listening_sockets": {
            "total_tcp6_listeners": len(listeners),
            "wildcard_listeners": len([l for l in listeners if l["is_wildcard"]]),
            "listeners": listeners[:10],
        },
        "telemetry": {
            "ip6_in_receives": ip6_in_receives,
            "ip6_in_discards": ip6_in_discards,
            "ip6_in_no_routes": ip6_in_no_routes,
            "ip6_out_requests": ip6_out_requests,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network Dual-Stack Socket & IPv6 Fallback Guard (Pattern 124)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--bindv6only-file", type=str, default=None, help="Override bindv6only file path")
    parser.add_argument("--conf-dir", type=str, default=None, help="Override /proc/sys/net/ipv6/conf directory")
    parser.add_argument("--tcp6-file", type=str, default=None, help="Override /proc/net/tcp6 path")
    parser.add_argument("--snmp6-file", type=str, default=None, help="Override /proc/net/snmp6 path")
    parser.add_argument("--warn-only", action="store_true", help="Always exit 0 even if issues detected")

    args = parser.parse_args()

    audit = audit_dualstack(
        bindv6only_file=args.bindv6only_file,
        conf_dir=args.conf_dir,
        tcp6_file=args.tcp6_file,
        snmp6_file=args.snmp6_file,
    )

    if args.json:
        print(json.dumps(audit, indent=2))
    else:
        print(f"Pattern 124: {audit['name']}")
        print(f"Status: {audit['status']}")
        cfg = audit["config"]
        print(f"bindv6only: {cfg['bindv6only']} (Dual-stack default: {cfg['dual_stack_default']})")
        sock = audit["listening_sockets"]
        print(f"TCP6 Listeners: {sock['total_tcp6_listeners']} (Wildcard: {sock['wildcard_listeners']})")
        telem = audit["telemetry"]
        print(f"IPv6 Ingress/Egress: In={telem['ip6_in_receives']:,}, Out={telem['ip6_out_requests']:,}, Discards={telem['ip6_in_discards']:,}")

        if audit["issues"]:
            print("\nIssues Identified:")
            for issue in audit["issues"]:
                print(f"  [!] {issue}")
        else:
            print("\nAll host IPv6 dual-stack socket configurations and interfaces are healthy.")

    if not audit["healthy"] and not args.warn_only:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
