#!/usr/bin/env python3
"""
bin/fm-jev-fwmark-reflect-guard.py - Host Dual-Stack Firewall Mark (fwmark) Reflection & Policy Routing Guard (Pattern 269 / Pattern 407)

Audits Linux kernel IPv4 and IPv6 socket buffer fwmark reflection, non-local address binding,
and FIB notification policies:
  - /proc/sys/net/ipv4/fwmark_reflect:
      Reflect incoming skb mark onto generated SYN-ACK and RST responses (0=disabled, 1=enabled).
  - /proc/sys/net/ipv6/fwmark_reflect:
      Reflect incoming IPv6 skb mark onto generated SYN-ACK and RST responses (0=disabled, 1=enabled).
  - /proc/sys/net/ipv4/ip_nonlocal_bind:
      Permit applications to bind to non-local IPv4 addresses (0=disabled, 1=enabled; transparent proxying/anycast).
  - /proc/sys/net/ipv6/ip_nonlocal_bind:
      Permit applications to bind to non-local IPv6 addresses (0=disabled, 1=enabled).
  - /proc/sys/net/ipv4/fib_notify_on_flag_change:
      Emit RTM_NEWROUTE notifications on FIB flag transitions (0=disabled, 1=notify, 2=notify on error).
  - /proc/sys/net/ipv6/fib_notify_on_flag_change:
      Emit RTM_NEWROUTE notifications on IPv6 FIB flag transitions.

Invariants:
  - fwmark_reflect must be 0 or 1.
  - ip_nonlocal_bind must be 0 or 1.
  - fib_notify_on_flag_change must be 0, 1, or 2.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths are missing or restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

SYSCTL_NET_BASE = "/proc/sys/net"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content else default
    except (ValueError, OSError, IndexError):
        return default


def audit_fwmark_reflect_guard(
    net_dir: str = SYSCTL_NET_BASE,
) -> Dict[str, Any]:
    issues: List[str] = []
    status = "HEALTHY"

    ipv4_dir = os.path.join(net_dir, "ipv4")
    ipv6_dir = os.path.join(net_dir, "ipv6")

    v4_fwmark_reflect = read_sysctl_int(os.path.join(ipv4_dir, "fwmark_reflect"), 0)
    v6_fwmark_reflect = read_sysctl_int(os.path.join(ipv6_dir, "fwmark_reflect"), 0)
    v4_nonlocal_bind = read_sysctl_int(os.path.join(ipv4_dir, "ip_nonlocal_bind"), 0)
    v6_nonlocal_bind = read_sysctl_int(os.path.join(ipv6_dir, "ip_nonlocal_bind"), 0)
    v4_fib_notify = read_sysctl_int(os.path.join(ipv4_dir, "fib_notify_on_flag_change"), 0)
    v6_fib_notify = read_sysctl_int(os.path.join(ipv6_dir, "fib_notify_on_flag_change"), 0)

    if v4_fwmark_reflect not in (0, 1):
        issues.append(f"Invalid ipv4.fwmark_reflect={v4_fwmark_reflect} (expected 0 or 1)")
        status = "WARNING"

    if v6_fwmark_reflect not in (0, 1):
        issues.append(f"Invalid ipv6.fwmark_reflect={v6_fwmark_reflect} (expected 0 or 1)")
        status = "WARNING"

    if v4_nonlocal_bind not in (0, 1):
        issues.append(f"Invalid ipv4.ip_nonlocal_bind={v4_nonlocal_bind} (expected 0 or 1)")
        status = "WARNING"

    if v6_nonlocal_bind not in (0, 1):
        issues.append(f"Invalid ipv6.ip_nonlocal_bind={v6_nonlocal_bind} (expected 0 or 1)")
        status = "WARNING"

    if v4_fib_notify not in (0, 1, 2):
        issues.append(f"Invalid ipv4.fib_notify_on_flag_change={v4_fib_notify} (expected 0..2)")
        status = "WARNING"

    if v6_fib_notify not in (0, 1, 2):
        issues.append(f"Invalid ipv6.fib_notify_on_flag_change={v6_fib_notify} (expected 0..2)")
        status = "WARNING"

    return {
        "pattern": 269,
        "name": "fwmark_reflect",
        "description": "Host Dual-Stack Firewall Mark (fwmark) Reflection & Policy Routing Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.timezone.utc and datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "ipv4_fwmark_reflect": v4_fwmark_reflect,
        "ipv6_fwmark_reflect": v6_fwmark_reflect,
        "ipv4_ip_nonlocal_bind": v4_nonlocal_bind,
        "ipv6_ip_nonlocal_bind": v6_nonlocal_bind,
        "ipv4_fib_notify_on_flag_change": v4_fib_notify,
        "ipv6_fib_notify_on_flag_change": v6_fib_notify,
        "policy_routing_symmetric": (v4_fwmark_reflect == v6_fwmark_reflect),
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Host Dual-Stack Firewall Mark (fwmark) Reflection & Policy Routing Guard (Pattern 269 / Pattern 407)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    parser.add_argument("--net-dir", default=SYSCTL_NET_BASE, help="Path to /proc/sys/net directory")

    args = parser.parse_args()

    report = audit_fwmark_reflect_guard(
        net_dir=args.net_dir,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Pattern 269: {report['name']} - Status: {report['status']}")
        print(f"  fwmark_reflect: ipv4={report['ipv4_fwmark_reflect']}, ipv6={report['ipv6_fwmark_reflect']} (symmetric={report['policy_routing_symmetric']})")
        print(f"  ip_nonlocal_bind: ipv4={report['ipv4_ip_nonlocal_bind']}, ipv6={report['ipv6_ip_nonlocal_bind']}")
        print(f"  fib_notify_on_flag_change: ipv4={report['ipv4_fib_notify_on_flag_change']}, ipv6={report['ipv6_fib_notify_on_flag_change']}")
        if report["issues"]:
            print("  Issues:")
            for issue in report["issues"]:
                print(f"    - {issue}")
        else:
            print("  Issues: none (nominal)")

    return 0 if report["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
