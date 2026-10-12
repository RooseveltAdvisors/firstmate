#!/usr/bin/env python3
"""
bin/fm-jev-if-inet6-guard.py - Host Network Interface IPv6 Address Scope, DAD & Lifetime Flags Guard (Pattern 246)

Audits Linux kernel IPv6 interface address configuration from /proc/net/if_inet6 and sysctl policies:
  - /proc/net/if_inet6 (Configured IPv6 addresses, scopes, flags, prefix lengths, interface bindings)
  - /proc/sys/net/ipv6/conf/all/disable_ipv6 (Global IPv6 protocol stack activation)
  - /proc/sys/net/ipv6/conf/default/disable_ipv6 (Default interface IPv6 stack activation)
  - /proc/sys/net/ipv6/conf/lo/disable_ipv6 (Loopback interface IPv6 stack activation)
  - /proc/sys/net/ipv6/conf/all/dad_transmits (Duplicate Address Detection solicitation count)

Invariants:
  - Immediate detection of DAD failure flag (IFA_F_DADFAILED = 0x08).
  - Immediate detection of addresses stuck in tentative state (IFA_F_TENTATIVE = 0x40).
  - Verification of loopback host scope address (::1 / 128 scope 0x10).
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysfs/procfs files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

DEFAULT_IF_INET6_PATH = "/proc/net/if_inet6"
DEFAULT_SYSCTL_IPV6_CONF_DIR = "/proc/sys/net/ipv6/conf"

IFA_F_SECONDARY = 0x01
IFA_F_NODAD = 0x02
IFA_F_OPTIMISTIC = 0x04
IFA_F_DADFAILED = 0x08
IFA_F_HOMEADDRESS = 0x10
IFA_F_DEPRECATED = 0x20
IFA_F_TENTATIVE = 0x40
IFA_F_PERMANENT = 0x80

SCOPE_NAMES = {
    0x00: "global",
    0x10: "host/loopback",
    0x20: "link-local",
    0x40: "site-local",
    0x80: "compat",
}


def hex_to_ipv6(hex_str: str) -> str:
    if len(hex_str) != 32:
        return hex_str
    groups = [hex_str[i:i+4] for i in range(0, 32, 4)]
    return ":".join(groups)


def parse_if_inet6_file(path: str = DEFAULT_IF_INET6_PATH) -> List[Dict[str, Any]]:
    entries: List[Dict[str, Any]] = []
    if not os.path.exists(path):
        return entries
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.read().strip().splitlines()
        for line in lines:
            parts = line.split()
            if len(parts) >= 6:
                addr_hex = parts[0]
                ifindex = int(parts[1], 16)
                prefix_len = int(parts[2], 16)
                scope = int(parts[3], 16)
                flags = int(parts[4], 16)
                ifname = parts[5]

                dad_failed = bool(flags & IFA_F_DADFAILED)
                tentative = bool(flags & IFA_F_TENTATIVE)
                deprecated = bool(flags & IFA_F_DEPRECATED)
                permanent = bool(flags & IFA_F_PERMANENT)

                entries.append({
                    "address": hex_to_ipv6(addr_hex),
                    "raw_hex": addr_hex,
                    "ifindex": ifindex,
                    "prefix_len": prefix_len,
                    "scope": scope,
                    "scope_name": SCOPE_NAMES.get(scope, f"0x{scope:02x}"),
                    "flags": flags,
                    "dad_failed": dad_failed,
                    "tentative": tentative,
                    "deprecated": deprecated,
                    "permanent": permanent,
                    "ifname": ifname,
                })
    except Exception:
        pass
    return entries


def read_sysctl_int(path: str, default: int = 0) -> int:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception:
        return default


def audit_if_inet6_guard(
    if_inet6_file: str = DEFAULT_IF_INET6_PATH,
    sysctl_conf_dir: str = DEFAULT_SYSCTL_IPV6_CONF_DIR,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []

    entries = parse_if_inet6_file(if_inet6_file)
    total_addresses = len(entries)
    dad_failed_count = sum(1 for e in entries if e.get("dad_failed"))
    tentative_count = sum(1 for e in entries if e.get("tentative"))
    deprecated_count = sum(1 for e in entries if e.get("deprecated"))

    all_disable = read_sysctl_int(os.path.join(sysctl_conf_dir, "all", "disable_ipv6"), default=0)
    default_disable = read_sysctl_int(os.path.join(sysctl_conf_dir, "default", "disable_ipv6"), default=0)
    lo_disable = read_sysctl_int(os.path.join(sysctl_conf_dir, "lo", "disable_ipv6"), default=0)
    dad_transmits = read_sysctl_int(os.path.join(sysctl_conf_dir, "all", "dad_transmits"), default=1)

    if dad_failed_count > 0:
        failed_addrs = [f"{e['ifname']}:{e['address']}" for e in entries if e.get("dad_failed")]
        issues.append(f"Critical IPv6 Duplicate Address Detection (DAD) failure on: {', '.join(failed_addrs)}")
        recommendations.append("Investigate duplicate IPv6 address collision across local subnet or bridge")

    if tentative_count > 0:
        tentative_addrs = [f"{e['ifname']}:{e['address']}" for e in entries if e.get("tentative")]
        issues.append(f"IPv6 address stuck in tentative state: {', '.join(tentative_addrs)}")
        recommendations.append("Check interface link state and neighbor solicitation / router advertisement reachability")

    if all_disable != 0:
        issues.append(f"IPv6 stack globally disabled (net.ipv6.conf.all.disable_ipv6={all_disable})")
        recommendations.append("Set net.ipv6.conf.all.disable_ipv6 = 0 via sysctl")

    if lo_disable != 0:
        issues.append(f"IPv6 loopback disabled (net.ipv6.conf.lo.disable_ipv6={lo_disable}); breaking local IPv6 IPC")
        recommendations.append("Set net.ipv6.conf.lo.disable_ipv6 = 0 via sysctl")

    has_loopback_v6 = any(e.get("ifname") == "lo" and e.get("prefix_len") == 128 for e in entries)
    if total_addresses > 0 and not has_loopback_v6:
        issues.append("Missing IPv6 host loopback address (::1/128) on lo interface")
        recommendations.append("Assign ::1/128 to interface lo")

    status = "HEALTHY" if len(issues) == 0 else "WARNING"

    return {
        "status": status,
        "healthy": len(issues) == 0,
        "total_addresses": total_addresses,
        "dad_failed_count": dad_failed_count,
        "tentative_count": tentative_count,
        "deprecated_count": deprecated_count,
        "all_disable_ipv6": all_disable,
        "default_disable_ipv6": default_disable,
        "lo_disable_ipv6": lo_disable,
        "dad_transmits": dad_transmits,
        "addresses": entries,
        "issues": issues,
        "recommendations": recommendations,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network Interface IPv6 Address Scope, DAD & Lifetime Flags Guard (Pattern 246)"
    )
    parser.add_argument("--if-inet6-file", default=DEFAULT_IF_INET6_PATH, help="Path to /proc/net/if_inet6")
    parser.add_argument("--sysctl-conf-dir", default=DEFAULT_SYSCTL_IPV6_CONF_DIR, help="Path to /proc/sys/net/ipv6/conf")
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--verbose", action="store_true", help="Verbose reporting")
    args = parser.parse_args()

    result = audit_if_inet6_guard(
        if_inet6_file=args.if_inet6_file,
        sysctl_conf_dir=args.sysctl_conf_dir,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] Host Network Interface IPv6 Address Guard (Pattern 246)")
        print(f"  Total IPv6 Addresses: {result['total_addresses']}")
        print(f"  DAD Failures:         {result['dad_failed_count']}")
        print(f"  Tentative Addresses:  {result['tentative_count']}")
        print(f"  Deprecated Addresses: {result['deprecated_count']}")
        print(f"  all_disable_ipv6:     {result['all_disable_ipv6']}")
        print(f"  lo_disable_ipv6:      {result['lo_disable_ipv6']}")
        print(f"  dad_transmits:        {result['dad_transmits']}")
        for a in result["addresses"]:
            print(f"    - {a['ifname']}: {a['address']}/{a['prefix_len']} (scope={a['scope_name']}, flags=0x{a['flags']:02x})")
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
