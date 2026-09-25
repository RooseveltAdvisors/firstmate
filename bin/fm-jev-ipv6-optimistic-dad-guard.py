#!/usr/bin/env python3
"""
bin/fm-jev-ipv6-optimistic-dad-guard.py - Linux IPv6 Optimistic DAD (RFC 4429) & Privacy Regeneration Policy Guard (Pattern 288 / Pattern 426)

Audits Linux kernel IPv6 Optimistic Duplicate Address Detection (RFC 4429), RFC 4941 privacy address
regeneration advance thresholds, and IPsec policy bypass parameters across network interfaces:
  - /proc/sys/net/ipv6/conf/*/use_optimistic: Allow optimistic addresses as source for outbound connections (default 0)
  - /proc/sys/net/ipv6/conf/*/optimistic_dad: Perform Optimistic DAD for configured addresses (default 0)
  - /proc/sys/net/ipv6/conf/*/regen_min_advance: Minimum lead time in seconds before address deprecation to regenerate (default 2s)
  - /proc/sys/net/ipv6/conf/*/disable_policy: Disable IPsec XFRM security policy checks per interface (default 0)
  - /proc/net/snmp6: Icmp6OutNeighborSolicits (DAD probes), Ip6InAddrErrors, Ip6InDiscards, Icmp6InCsumErrors

Invariants:
  - regen_min_advance must be >= 1s and <= 60s (RFC 4941 §3.5 lead time constraint).
  - disable_policy must be 0 on non-loopback interfaces to maintain cryptographic security boundary.
  - use_optimistic must be 0 or 1.
  - Fail-open: graceful fallback when sysctl paths or /proc/net/snmp6 are restricted.
  - Fast bounded execution (< 0.02s).
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
        return int(content.split()[0]) if content and (content.split()[0].lstrip("-").isdigit()) else default
    except (ValueError, OSError, IndexError):
        return default


def parse_snmp6(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 2:
                    try:
                        metrics[parts[0]] = int(parts[1])
                    except ValueError:
                        pass
    except Exception:
        pass
    return metrics


def audit_ipv6_optimistic_dad_guard(
    conf_dir: str = CONF_IPV6_BASE,
    snmp6_path: str = PROC_SNMP6,
    min_advance_floor: int = 1,
    max_advance_ceil: int = 60,
) -> Dict[str, Any]:
    interfaces: Dict[str, Dict[str, int]] = {}

    if os.path.isdir(conf_dir):
        for entry in sorted(os.listdir(conf_dir)):
            iface_path = os.path.join(conf_dir, entry)
            if os.path.isdir(iface_path):
                interfaces[entry] = {
                    "optimistic_dad": read_sysctl_int(os.path.join(iface_path, "optimistic_dad"), default=0),
                    "use_optimistic": read_sysctl_int(os.path.join(iface_path, "use_optimistic"), default=0),
                    "regen_min_advance": read_sysctl_int(os.path.join(iface_path, "regen_min_advance"), default=2),
                    "disable_policy": read_sysctl_int(os.path.join(iface_path, "disable_policy"), default=0),
                }

    snmp6 = parse_snmp6(snmp6_path)
    out_ns = snmp6.get("Icmp6OutNeighborSolicits", 0)
    in_addr_errors = snmp6.get("Ip6InAddrErrors", 0)
    in_discards = snmp6.get("Ip6InDiscards", 0)
    in_errors = snmp6.get("Icmp6InErrors", 0)
    in_csum_errors = snmp6.get("Icmp6InCsumErrors", 0)

    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    for ifname, params in interfaces.items():
        opt_dad = params["optimistic_dad"]
        use_opt = params["use_optimistic"]
        advance = params["regen_min_advance"]
        dis_policy = params["disable_policy"]

        if opt_dad not in (0, 1):
            issues.append(f"Interface {ifname}: invalid optimistic_dad configuration ({opt_dad})")
            status = "WARNING"
            recommendations.append(f"Set /proc/sys/net/ipv6/conf/{ifname}/optimistic_dad to 0 or 1.")

        if use_opt not in (0, 1):
            issues.append(f"Interface {ifname}: invalid use_optimistic configuration ({use_opt})")
            status = "WARNING"
            recommendations.append(f"Set /proc/sys/net/ipv6/conf/{ifname}/use_optimistic to 0 or 1.")

        if advance < min_advance_floor:
            issues.append(
                f"Interface {ifname}: regen_min_advance ({advance}s) is below minimum threshold "
                f"({min_advance_floor}s); risk of temporary address expiration before regeneration"
            )
            if status != "CRITICAL":
                status = "WARNING"
            recommendations.append(f"Set /proc/sys/net/ipv6/conf/{ifname}/regen_min_advance to >= {min_advance_floor}s.")
        elif advance > max_advance_ceil:
            issues.append(
                f"Interface {ifname}: excessive regen_min_advance ({advance}s > {max_advance_ceil}s); "
                "premature address regeneration churn"
            )
            if status != "CRITICAL":
                status = "WARNING"
            recommendations.append(f"Set /proc/sys/net/ipv6/conf/{ifname}/regen_min_advance to <= {max_advance_ceil}s.")

        if ifname not in ("lo", "all", "default") and dis_policy != 0:
            issues.append(
                f"Interface {ifname}: IPsec security policy check disabled (disable_policy={dis_policy}); "
                "traffic bypasses XFRM security checks"
            )
            status = "CRITICAL"
            recommendations.append(f"Set /proc/sys/net/ipv6/conf/{ifname}/disable_policy to 0.")

    if in_addr_errors > 100:
        issues.append(f"Elevated IPv6 inbound address errors detected (Ip6InAddrErrors={in_addr_errors})")
        if status != "CRITICAL":
            status = "WARNING"
        recommendations.append("Investigate faulty IPv6 routing or malformed destination addresses.")

    if in_csum_errors > 0:
        issues.append(f"ICMPv6 checksum errors detected (Icmp6InCsumErrors={in_csum_errors})")
        if status != "CRITICAL":
            status = "WARNING"
        recommendations.append("Check link layer hardware offloads or packet corruption on interface.")

    healthy = (status == "HEALTHY")

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": healthy,
        "interfaces_audited": len(interfaces),
        "all_optimistic_dad": interfaces.get("all", {}).get("optimistic_dad", 0),
        "default_optimistic_dad": interfaces.get("default", {}).get("optimistic_dad", 0),
        "all_use_optimistic": interfaces.get("all", {}).get("use_optimistic", 0),
        "default_use_optimistic": interfaces.get("default", {}).get("use_optimistic", 0),
        "default_regen_min_advance_sec": interfaces.get("default", {}).get("regen_min_advance", 2),
        "all_disable_policy": interfaces.get("all", {}).get("disable_policy", 0),
        "out_neighbor_solicits": out_ns,
        "in_addr_errors": in_addr_errors,
        "in_discards": in_discards,
        "in_errors": in_errors,
        "in_csum_errors": in_csum_errors,
        "dad_policy_compliant": healthy,
        "issues": issues,
        "recommendations": recommendations,
        "interfaces": interfaces,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IPv6 Optimistic DAD (RFC 4429) & Privacy Regeneration Policy Guard (Pattern 288 / Pattern 426)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--conf-dir", default=CONF_IPV6_BASE, help="Path to IPv6 conf sysctl directory")
    parser.add_argument("--snmp6-file", default=PROC_SNMP6, help="Path to /proc/net/snmp6")
    args = parser.parse_args()

    res = audit_ipv6_optimistic_dad_guard(
        conf_dir=args.conf_dir,
        snmp6_path=args.snmp6_file,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        status_sym = "✓" if res["healthy"] else "✗"
        print(f"[{status_sym}] IPv6 Optimistic DAD Guard: {res['status']}")
        print(f"    Interfaces: audited={res.get('interfaces_audited', 0)} | all_optimistic_dad={res.get('all_optimistic_dad', 0)} | default_optimistic_dad={res.get('default_optimistic_dad', 0)}")
        print(f"    Parameters: all_use_optimistic={res.get('all_use_optimistic', 0)} | regen_min_advance={res.get('default_regen_min_advance_sec', 0)}s | disable_policy={res.get('all_disable_policy', 0)}")
        print(f"    SNMP6 Telemetry: out_neighbor_solicits={res.get('out_neighbor_solicits', 0)} | in_addr_errors={res.get('in_addr_errors', 0)} | in_csum_errors={res.get('in_csum_errors', 0)}")
        if res["issues"]:
            print("    Issues:")
            for iss in res["issues"]:
                print(f"      - {iss}")
        if res["recommendations"]:
            print("    Recommendations:")
            for rec in res["recommendations"]:
                print(f"      - {rec}")

    return 0 if res["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
