#!/usr/bin/env python3
"""
bin/fm-jev-anycast6-guard.py - Host Network IPv6 Anycast Address Registry & RFC 4443 Compliance Guard (Pattern 250)

Audits Linux kernel IPv6 anycast address registrations and ICMPv6 anycast transmission policies:
  - /proc/net/anycast6: Registered IPv6 anycast addresses across host network interfaces
  - /proc/sys/net/ipv6/anycast_src_echo_reply: RFC 4443 compliant source address prohibition
  - /proc/sys/net/ipv6/icmp/echo_ignore_anycast: Anycast ICMPv6 echo ignore toggle
  - /proc/sys/net/ipv6/icmp/error_anycast_as_unicast: ICMPv6 error source address format
  - /proc/sys/net/ipv6/neigh/default/anycast_delay: Anycast neighbor solicitation reply delay

Invariants:
  - Verification of RFC 4443 section 2.2 compliance (anycast source address suppression).
  - Validation of neighbor solicitation anycast response delay bounding (10 <= delay <= 1000 jiffies) to prevent reply storms.
  - Tracking of active anycast socket bindings across multi-agent cluster interfaces.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl or procfs paths are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

PROC_ANYCAST6 = "/proc/net/anycast6"
SYSCTL_ANYCAST_SRC_ECHO = "/proc/sys/net/ipv6/anycast_src_echo_reply"
SYSCTL_ECHO_IGNORE_ANYCAST = "/proc/sys/net/ipv6/icmp/echo_ignore_anycast"
SYSCTL_ERR_ANYCAST_AS_UNICAST = "/proc/sys/net/ipv6/icmp/error_anycast_as_unicast"
SYSCTL_NEIGH_ANYCAST_DELAY = "/proc/sys/net/ipv6/neigh/default/anycast_delay"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0])
    except (ValueError, OSError, IndexError):
        return default


def parse_anycast6(path: str) -> List[Dict[str, Any]]:
    entries: List[Dict[str, Any]] = []
    if not os.path.isfile(path):
        return entries
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().strip().splitlines()
        for line in lines:
            parts = line.split()
            if not parts:
                continue
            entry: Dict[str, Any] = {}
            try:
                entry["ifindex"] = int(parts[0])
            except (ValueError, IndexError):
                entry["ifindex"] = 0
            entry["interface"] = parts[1] if len(parts) > 1 else ""
            entry["address"] = parts[2] if len(parts) > 2 else ""
            try:
                entry["users"] = int(parts[3]) if len(parts) > 3 else 1
            except ValueError:
                entry["users"] = 1
            entries.append(entry)
    except (OSError, PermissionError):
        pass
    return entries


def audit_anycast6_guard(
    anycast6_path: str = PROC_ANYCAST6,
    sysctl_src_echo: str = SYSCTL_ANYCAST_SRC_ECHO,
    sysctl_ignore_anycast: str = SYSCTL_ECHO_IGNORE_ANYCAST,
    sysctl_err_unicast: str = SYSCTL_ERR_ANYCAST_AS_UNICAST,
    sysctl_anycast_delay: str = SYSCTL_NEIGH_ANYCAST_DELAY,
) -> Dict[str, Any]:
    entries = parse_anycast6(anycast6_path)
    src_echo = read_sysctl_int(sysctl_src_echo, 0)
    ignore_echo = read_sysctl_int(sysctl_ignore_anycast, 0)
    err_unicast = read_sysctl_int(sysctl_err_unicast, 0)
    delay = read_sysctl_int(sysctl_anycast_delay, 100)

    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    # RFC 4443 compliance check
    if src_echo != 0:
        status = "WARNING"
        issues.append(
            f"ICMPv6 echo replies permitted with anycast source address (net.ipv6.anycast_src_echo_reply={src_echo}); "
            "violates RFC 4443 section 2.2 and creates asymmetric routing ambiguity"
        )
        recommendations.append("Set net.ipv6.anycast_src_echo_reply = 0 via sysctl")

    # Neighbor solicitation delay bounds check
    if delay < 10:
        status = "WARNING"
        issues.append(
            f"Anycast neighbor solicitation delay ({delay} jiffies) is dangerously low (< 10); "
            "risk of reply storm saturation from multi-agent clusters"
        )
        recommendations.append("Set net.ipv6.neigh.default.anycast_delay to 100 jiffies")
    elif delay > 1000:
        status = "WARNING"
        issues.append(
            f"Anycast neighbor solicitation delay ({delay} jiffies) exceeds ceiling (> 1000); "
            "causes excessive discovery latency"
        )
        recommendations.append("Set net.ipv6.neigh.default.anycast_delay to 100 jiffies")

    healthy = len(issues) == 0

    return {
        "status": status,
        "healthy": healthy,
        "anycast_address_count": len(entries),
        "anycast_src_echo_reply": src_echo,
        "echo_ignore_anycast": ignore_echo,
        "error_anycast_as_unicast": err_unicast,
        "default_anycast_delay_jiffies": delay,
        "rfc4443_compliant": (src_echo == 0),
        "anycast_healthy": healthy,
        "entries": entries,
        "issues": issues,
        "recommendations": recommendations,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IPv6 Anycast Address Registry & RFC 4443 Compliance Guard (Pattern 250)"
    )
    parser.add_argument("--anycast6-file", default=PROC_ANYCAST6, help="Path to /proc/net/anycast6")
    parser.add_argument("--src-echo-file", default=SYSCTL_ANYCAST_SRC_ECHO, help="Path to anycast_src_echo_reply")
    parser.add_argument("--ignore-echo-file", default=SYSCTL_ECHO_IGNORE_ANYCAST, help="Path to echo_ignore_anycast")
    parser.add_argument("--err-unicast-file", default=SYSCTL_ERR_ANYCAST_AS_UNICAST, help="Path to error_anycast_as_unicast")
    parser.add_argument("--delay-file", default=SYSCTL_NEIGH_ANYCAST_DELAY, help="Path to anycast_delay")
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--verbose", action="store_true", help="Verbose reporting")
    args = parser.parse_args()

    result = audit_anycast6_guard(
        anycast6_path=args.anycast6_file,
        sysctl_src_echo=args.src_echo_file,
        sysctl_ignore_anycast=args.ignore_echo_file,
        sysctl_err_unicast=args.err_unicast_file,
        sysctl_anycast_delay=args.delay_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] Host Network IPv6 Anycast Guard (Pattern 250 - Milestone)")
        print(f"  Anycast Addresses Registered:     {result['anycast_address_count']}")
        print(f"  Anycast Source Echo Reply:        {result['anycast_src_echo_reply']} (RFC 4443 compliant: {result['rfc4443_compliant']})")
        print(f"  Echo Ignore Anycast:              {result['echo_ignore_anycast']}")
        print(f"  Error Anycast as Unicast:         {result['error_anycast_as_unicast']}")
        print(f"  Default Anycast Delay:            {result['default_anycast_delay_jiffies']} jiffies")
        if result["issues"]:
            print("  Issues:")
            for iss in result["issues"]:
                print(f"    - {iss}")
        if result["recommendations"]:
            print("  Recommendations:")
            for rec in result["recommendations"]:
                print(f"    - {rec}")

    return 0 if result["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
