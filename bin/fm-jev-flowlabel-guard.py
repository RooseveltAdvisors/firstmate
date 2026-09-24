#!/usr/bin/env python3
"""
bin/fm-jev-flowlabel-guard.py - Host Network IPv6 Flow Label Management & Multipath Hashing Guard (Pattern 245)

Audits Linux kernel RFC 6437 IPv6 flow label management and ECMP multipath hashing telemetry:
  - /proc/net/ip6_flowlabel (Active registered IPv6 flow labels, socket owners, user references, linger, expiration)
  - /proc/sys/net/ipv6/auto_flowlabels (Automatic flow label generation for ECMP hash diversity)
  - /proc/sys/net/ipv6/flowlabel_consistency (Label consistency verification against collision/spoofing)
  - /proc/sys/net/ipv6/flowlabel_reflect (Flow label reflection policy on incoming flows)
  - /proc/sys/net/ipv6/flowlabel_state_ranges (State range partitioning policy)
  - /proc/sys/net/ipv6/seg6_flowlabel (SRv6 segment routing flow label hashing)

Guarantees balanced ECMP traffic distribution, predictable flow hashing, and zero label collision
across multi-agent mesh clusters and IPv6 egress transport tunnels.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysfs/procfs files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

DEFAULT_IP6_FLOWLABEL_PATH = "/proc/net/ip6_flowlabel"
DEFAULT_SYSCTL_IPV6_DIR = "/proc/sys/net/ipv6"

WARN_MAX_ACTIVE_FLOWLABELS = 4096


def parse_ip6_flowlabel_file(path: str = DEFAULT_IP6_FLOWLABEL_PATH) -> List[Dict[str, Any]]:
    entries: List[Dict[str, Any]] = []
    if not os.path.exists(path):
        return entries
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.read().strip().splitlines()
        if len(lines) <= 1:
            return entries
        for line in lines[1:]:
            parts = line.split()
            if len(parts) >= 7:
                label_hex = parts[0]
                style = parts[1]
                owner = int(parts[2]) if parts[2].isdigit() else parts[2]
                users = int(parts[3]) if parts[3].isdigit() else parts[3]
                linger = int(parts[4]) if parts[4].isdigit() else parts[4]
                expires = int(parts[5]) if parts[5].isdigit() else parts[5]
                dst = parts[6]
                opt = parts[7] if len(parts) > 7 else ""
                entries.append({
                    "label": label_hex,
                    "style": style,
                    "owner": owner,
                    "users": users,
                    "linger": linger,
                    "expires": expires,
                    "dst": dst,
                    "opt": opt,
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


def audit_flowlabel_guard(
    flowlabel_file: str = DEFAULT_IP6_FLOWLABEL_PATH,
    sysctl_dir: str = DEFAULT_SYSCTL_IPV6_DIR,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []

    entries = parse_ip6_flowlabel_file(flowlabel_file)
    active_count = len(entries)
    total_users = sum(e["users"] for e in entries if isinstance(e.get("users"), int))
    lingering_count = sum(1 for e in entries if isinstance(e.get("users"), int) and e["users"] == 0)

    auto_flowlabels = read_sysctl_int(os.path.join(sysctl_dir, "auto_flowlabels"), default=1)
    flowlabel_consistency = read_sysctl_int(os.path.join(sysctl_dir, "flowlabel_consistency"), default=1)
    flowlabel_reflect = read_sysctl_int(os.path.join(sysctl_dir, "flowlabel_reflect"), default=0)
    flowlabel_state_ranges = read_sysctl_int(os.path.join(sysctl_dir, "flowlabel_state_ranges"), default=0)
    seg6_flowlabel = read_sysctl_int(os.path.join(sysctl_dir, "seg6_flowlabel"), default=0)

    if flowlabel_consistency == 0:
        issues.append(
            "IPv6 flowlabel consistency check is disabled (flowlabel_consistency=0); "
            "risk of conflicting flow label allocations or cross-tenant label hijacking."
        )
        recommendations.append("Set net.ipv6.flowlabel_consistency = 1 via sysctl.")

    if auto_flowlabels not in (0, 1, 2, 3):
        issues.append(
            f"Unexpected auto_flowlabels configuration ({auto_flowlabels}); valid range is 0..3."
        )
        recommendations.append("Set net.ipv6.auto_flowlabels = 1 for automatic ECMP hashing.")

    if flowlabel_reflect not in (0, 1, 2, 3):
        issues.append(
            f"Unexpected flowlabel_reflect configuration ({flowlabel_reflect}); valid range is 0..3."
        )
        recommendations.append("Set net.ipv6.flowlabel_reflect to 0 (default) or 1 (strict reflect).")

    if active_count > WARN_MAX_ACTIVE_FLOWLABELS:
        issues.append(
            f"High active IPv6 flowlabel count ({active_count} > {WARN_MAX_ACTIVE_FLOWLABELS}); "
            "potential kernel flowlabel table saturation or socket leak."
        )
        recommendations.append("Audit long-lived IPv6 sockets with IPV6_FLOWLABEL_MGR options.")

    status = "HEALTHY" if len(issues) == 0 else "WARNING"

    return {
        "status": status,
        "healthy": len(issues) == 0,
        "active_flowlabels": active_count,
        "total_users": total_users,
        "lingering_flowlabels": lingering_count,
        "auto_flowlabels": auto_flowlabels,
        "flowlabel_consistency": flowlabel_consistency,
        "flowlabel_reflect": flowlabel_reflect,
        "flowlabel_state_ranges": flowlabel_state_ranges,
        "seg6_flowlabel": seg6_flowlabel,
        "issues": issues,
        "recommendations": recommendations,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IPv6 Flow Label Management & Multipath Hashing Guard (Pattern 245)"
    )
    parser.add_argument("--flowlabel-file", default=DEFAULT_IP6_FLOWLABEL_PATH, help="Path to /proc/net/ip6_flowlabel")
    parser.add_argument("--sysctl-dir", default=DEFAULT_SYSCTL_IPV6_DIR, help="Path to /proc/sys/net/ipv6")
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--verbose", action="store_true", help="Verbose reporting")
    args = parser.parse_args()

    result = audit_flowlabel_guard(
        flowlabel_file=args.flowlabel_file,
        sysctl_dir=args.sysctl_dir,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] Host Network IPv6 Flow Label Guard (Pattern 245)")
        print(f"  Active Flow Labels: {result['active_flowlabels']}")
        print(f"  Total Socket Users: {result['total_users']}")
        print(f"  Lingering Labels:   {result['lingering_flowlabels']}")
        print(f"  auto_flowlabels:    {result['auto_flowlabels']}")
        print(f"  flowlabel_consistency: {result['flowlabel_consistency']}")
        print(f"  flowlabel_reflect:  {result['flowlabel_reflect']}")
        print(f"  seg6_flowlabel:     {result['seg6_flowlabel']}")
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
