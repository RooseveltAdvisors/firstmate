#!/usr/bin/env python3
"""
bin/fm-jev-netns-policy-guard.py - Host Network Namespace Configuration Inheritance & Tunnel Policy Guard (Pattern 251)

Audits Linux kernel network namespace policy parameters and fallback tunnel creation controls:
  - /proc/sys/net/core/devconf_inherit_init_net: Devconf inheritance from init_net into child netns
  - /proc/sys/net/core/fb_tunnels_only_for_init_net: Fallback tunnel creation suppression in child netns
  - /proc/sys/net/netfilter/nf_hooks_lwtunnel: Lightweight tunnel netfilter hook execution
  - /proc/sys/user/max_net_namespaces: User namespace network sandbox capacity ceiling

Invariants:
  - Validation of container and agent sandbox network isolation policies.
  - Identification of fallback tunnel interface sprawl across ephemeral namespaces.
  - Verification that user namespace network capacity meets multi-agent sandbox requirements.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

SYSCTL_DEVCONF_INHERIT = "/proc/sys/net/core/devconf_inherit_init_net"
SYSCTL_FB_TUNNELS = "/proc/sys/net/core/fb_tunnels_only_for_init_net"
SYSCTL_LWTUNNEL_HOOKS = "/proc/sys/net/netfilter/nf_hooks_lwtunnel"
SYSCTL_MAX_NETNS = "/proc/sys/user/max_net_namespaces"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0])
    except (ValueError, OSError, IndexError):
        return default


def audit_netns_policy_guard(
    sysctl_devconf_inherit: str = SYSCTL_DEVCONF_INHERIT,
    sysctl_fb_tunnels: str = SYSCTL_FB_TUNNELS,
    sysctl_lwtunnel_hooks: str = SYSCTL_LWTUNNEL_HOOKS,
    sysctl_max_netns: str = SYSCTL_MAX_NETNS,
    min_netns_thresh: int = 1024,
) -> Dict[str, Any]:
    devconf_inherit = read_sysctl_int(sysctl_devconf_inherit, 0)
    fb_tunnels = read_sysctl_int(sysctl_fb_tunnels, 0)
    lwtunnel_hooks = read_sysctl_int(sysctl_lwtunnel_hooks, 0)
    max_netns = read_sysctl_int(sysctl_max_netns, 254663)

    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    if max_netns < min_netns_thresh:
        status = "WARNING"
        issues.append(
            f"Constrained network namespace ceiling (user.max_net_namespaces={max_netns} < {min_netns_thresh}); "
            "risk of ENOSPC during multi-agent sandbox creation"
        )
        recommendations.append("Increase user.max_net_namespaces to at least 4096 via sysctl")

    healthy = len(issues) == 0

    return {
        "status": status,
        "healthy": healthy,
        "devconf_inherit_init_net": devconf_inherit,
        "fb_tunnels_only_for_init_net": fb_tunnels,
        "nf_hooks_lwtunnel": lwtunnel_hooks,
        "max_net_namespaces": max_netns,
        "devconf_inheritance_active": (devconf_inherit > 0),
        "fallback_tunnel_suppression_active": (fb_tunnels > 0),
        "lwtunnel_filtering_active": (lwtunnel_hooks == 1),
        "netns_policy_healthy": healthy,
        "issues": issues,
        "recommendations": recommendations,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network Namespace Configuration Inheritance & Tunnel Policy Guard (Pattern 251)"
    )
    parser.add_argument("--devconf-inherit-file", default=SYSCTL_DEVCONF_INHERIT, help="Path to devconf_inherit_init_net")
    parser.add_argument("--fb-tunnels-file", default=SYSCTL_FB_TUNNELS, help="Path to fb_tunnels_only_for_init_net")
    parser.add_argument("--lwtunnel-hooks-file", default=SYSCTL_LWTUNNEL_HOOKS, help="Path to nf_hooks_lwtunnel")
    parser.add_argument("--max-netns-file", default=SYSCTL_MAX_NETNS, help="Path to user.max_net_namespaces")
    parser.add_argument("--min-netns-thresh", type=int, default=1024, help="Minimum network namespaces threshold")
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--verbose", action="store_true", help="Verbose reporting")
    args = parser.parse_args()

    result = audit_netns_policy_guard(
        sysctl_devconf_inherit=args.devconf_inherit_file,
        sysctl_fb_tunnels=args.fb_tunnels_file,
        sysctl_lwtunnel_hooks=args.lwtunnel_hooks_file,
        sysctl_max_netns=args.max_netns_file,
        min_netns_thresh=args.min_netns_thresh,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] Host Network Namespace & Tunnel Policy Guard (Pattern 251)")
        print(f"  Devconf Inherit Init Net:         {result['devconf_inherit_init_net']} (Active: {result['devconf_inheritance_active']})")
        print(f"  Fallback Tunnels Init Only:       {result['fb_tunnels_only_for_init_net']} (Suppression Active: {result['fallback_tunnel_suppression_active']})")
        print(f"  LWTunnel Netfilter Hooks:         {result['nf_hooks_lwtunnel']} (Filtering Active: {result['lwtunnel_filtering_active']})")
        print(f"  Max Network Namespaces:           {result['max_net_namespaces']:,}")
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
