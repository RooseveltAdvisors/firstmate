#!/usr/bin/env python3
"""
bin/fm-jev-ipv6-hop-limit-guard.py - Host IPv6 Default Hop Limit & Time Exceeded Guard (Pattern 266 / Pattern 404)

Audits Linux kernel IPv6 Hop Limit configuration (RFC 4861 §6.3.2, RFC 8200 §3)
and datagram delivery telemetry:
  - conf/*/hop_limit:
      Default Hop Limit for outgoing IPv6 packets (RFC default: 64, range: 1..255)
  - conf/*/accept_ra_min_hop_limit:
      Minimum hop limit accepted from router advertisements (default: 1)
  - /proc/net/snmp6:
      Ip6InReceives = total inbound IPv6 datagrams
      Ip6InHdrErrors = header discards (including hop limit == 0)
      Ip6InDelivers = delivered datagrams
      Ip6OutRequests = locally generated outbound datagrams
      Icmp6InTimeExceeded = incoming ICMPv6 Time Exceeded
      Icmp6OutTimeExceeded = outgoing ICMPv6 Time Exceeded

Invariants:
  - hop_limit must be within valid range [1, 255] (warning if < 32 or > 255).
  - accept_ra_min_hop_limit must be >= 1 to prevent rogue RA zero/low hop limit injection.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths or snmp6 are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

CONF_IPV6_BASE = "/proc/sys/net/ipv6/conf"
PROC_SNMP6 = "/proc/net/snmp6"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content else default
    except (ValueError, OSError, IndexError):
        return default


def parse_snmp6_hop_limit(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {
        "Ip6InReceives": 0,
        "Ip6InHdrErrors": 0,
        "Ip6InDelivers": 0,
        "Ip6OutRequests": 0,
        "Icmp6InTimeExceeded": 0,
        "Icmp6OutTimeExceeded": 0,
    }
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 2 and parts[0] in metrics:
                    try:
                        metrics[parts[0]] = int(parts[1])
                    except ValueError:
                        pass
    except OSError:
        pass
    return metrics


def audit_ipv6_hop_limit_guard(
    conf_dir: str = CONF_IPV6_BASE,
    snmp6_path: str = PROC_SNMP6,
    min_safe_hop_limit: int = 32,
) -> Dict[str, Any]:
    interfaces: Dict[str, Dict[str, Any]] = {}
    issues: List[str] = []
    status = "HEALTHY"

    if os.path.isdir(conf_dir):
        try:
            for ifname in sorted(os.listdir(conf_dir)):
                iface_path = os.path.join(conf_dir, ifname)
                if os.path.isdir(iface_path):
                    hop_p = os.path.join(iface_path, "hop_limit")
                    min_ra_p = os.path.join(iface_path, "accept_ra_min_hop_limit")

                    if os.path.isfile(hop_p):
                        hop_val = read_sysctl_int(hop_p, -1)
                        min_ra_val = read_sysctl_int(min_ra_p, 1)

                        if hop_val < 1 or hop_val > 255:
                            issues.append(f"Interface {ifname} has out-of-range hop_limit={hop_val}")
                            status = "WARNING"
                        elif hop_val < min_safe_hop_limit:
                            issues.append(
                                f"Interface {ifname} hop_limit={hop_val} below safe floor {min_safe_hop_limit}"
                            )
                            status = "WARNING"

                        if min_ra_val < 1:
                            issues.append(
                                f"Interface {ifname} accept_ra_min_hop_limit={min_ra_val} < 1 (risk of zero hop limit injection)"
                            )
                            status = "WARNING"

                        interfaces[ifname] = {
                            "hop_limit": hop_val,
                            "accept_ra_min_hop_limit": min_ra_val,
                        }
        except OSError:
            pass

    snmp6_metrics = parse_snmp6_hop_limit(snmp6_path)
    in_receives = snmp6_metrics.get("Ip6InReceives", 0)
    in_hdr_errors = snmp6_metrics.get("Ip6InHdrErrors", 0)
    in_delivers = snmp6_metrics.get("Ip6InDelivers", 0)
    out_requests = snmp6_metrics.get("Ip6OutRequests", 0)
    in_time_exceeded = snmp6_metrics.get("Icmp6InTimeExceeded", 0)
    out_time_exceeded = snmp6_metrics.get("Icmp6OutTimeExceeded", 0)

    default_hop = interfaces.get("default", {}).get("hop_limit", 64)
    all_hop = interfaces.get("all", {}).get("hop_limit", 64)

    return {
        "pattern": 266,
        "name": "ipv6_hop_limit",
        "description": "Host IPv6 Default Hop Limit & Time Exceeded Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.timezone.utc and datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "interfaces_audited": len(interfaces),
        "default_hop_limit": default_hop,
        "all_hop_limit": all_hop,
        "in_receives": in_receives,
        "in_hdr_errors": in_hdr_errors,
        "in_delivers": in_delivers,
        "out_requests": out_requests,
        "in_time_exceeded": in_time_exceeded,
        "out_time_exceeded": out_time_exceeded,
        "interfaces": interfaces,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Host IPv6 Default Hop Limit & Time Exceeded Guard (Pattern 266 / Pattern 404)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    parser.add_argument("--conf-dir", default=CONF_IPV6_BASE, help="Path to /proc/sys/net/ipv6/conf directory")
    parser.add_argument("--snmp6-file", default=PROC_SNMP6, help="Path to /proc/net/snmp6")
    parser.add_argument(
        "--min-safe-hop-limit", type=int, default=32, help="Minimum safe default hop limit floor"
    )

    args = parser.parse_args()

    report = audit_ipv6_hop_limit_guard(
        conf_dir=args.conf_dir,
        snmp6_path=args.snmp6_file,
        min_safe_hop_limit=args.min_safe_hop_limit,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Pattern 266: {report['name']} - Status: {report['status']}")
        print(f"  interfaces_audited: {report['interfaces_audited']}")
        print(f"  default_hop_limit: {report['default_hop_limit']}")
        print(f"  all_hop_limit: {report['all_hop_limit']}")
        print(f"  in_receives: {report['in_receives']}, in_delivers: {report['in_delivers']}, out_requests: {report['out_requests']}")
        print(f"  in_hdr_errors: {report['in_hdr_errors']}, time_exceeded: in={report['in_time_exceeded']}, out={report['out_time_exceeded']}")
        if report["issues"]:
            print("  Issues:")
            for issue in report["issues"]:
                print(f"    - {issue}")
        else:
            print("  Issues: none (nominal)")

    return 0 if report["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
