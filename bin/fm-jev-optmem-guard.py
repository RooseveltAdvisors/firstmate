#!/usr/bin/env python3
"""
bin/fm-jev-optmem-guard.py - Host Network Core Socket Ancillary Buffer & SKB Page Fragment Guard (Pattern 276 / Pattern 414)

Audits Linux kernel core networking socket ancillary memory and SKB page fragment limits:
  - /proc/sys/net/core/optmem_max:
      Maximum ancillary buffer memory allowed per socket (cmsg, BPF filter, setsockopt).
  - /proc/sys/net/core/max_skb_frags:
      Maximum number of paged fragments allowed per sk_buff (default 17).
  - /proc/sys/net/core/high_order_alloc_disable:
      Higher-order page allocation policy (0=enabled for GRO/frags).
  - /proc/sys/net/core/netdev_unregister_timeout_secs:
      Network device unregister refcount timeout.

Invariants:
  - optmem_max >= 20480 (prevent ENOBUFS on BPF filter attachment / cmsg metadata).
  - optmem_max <= 16777216 (prevent unprivileged slab memory exhaustion).
  - max_skb_frags between 16 and 64.
  - high_order_alloc_disable == 0.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths are missing.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

PROC_CORE_DIR = "/proc/sys/net/core"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content else default
    except (ValueError, OSError, IndexError):
        return default


def audit_optmem_guard(
    conf_dir: str = PROC_CORE_DIR,
    min_optmem_bytes: int = 20480,
    max_optmem_bytes: int = 16777216,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    if not os.path.isdir(conf_dir):
        return {
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "status": "UNKNOWN",
            "healthy": True,
            "conf_dir": conf_dir,
            "error": "Core net sysctl directory not found",
            "issues": [],
            "recommendations": [],
        }

    optmem_max = read_sysctl_int(os.path.join(conf_dir, "optmem_max"), 20480)
    max_skb_frags = read_sysctl_int(os.path.join(conf_dir, "max_skb_frags"), 17)
    high_order_alloc_disable = read_sysctl_int(os.path.join(conf_dir, "high_order_alloc_disable"), 0)
    unregister_timeout = read_sysctl_int(os.path.join(conf_dir, "netdev_unregister_timeout_secs"), 10)

    if optmem_max < min_optmem_bytes and optmem_max != -1:
        issues.append(
            f"Constrained socket ancillary buffer memory ({optmem_max} B < {min_optmem_bytes} B); "
            "risks ENOBUFS errors on BPF filter attachment, eBPF sockopt, or cmsg control message dispatch"
        )
        recommendations.append(f"Increase net.core.optmem_max to at least {min_optmem_bytes} bytes")
    elif optmem_max > max_optmem_bytes:
        issues.append(
            f"Excessive socket ancillary buffer limit ({optmem_max} B > {max_optmem_bytes} B); "
            "risks unprivileged slab memory exhaustion under high socket churn"
        )
        recommendations.append(f"Clamp net.core.optmem_max to at most {max_optmem_bytes} bytes")

    if max_skb_frags < 16 and max_skb_frags != -1:
        issues.append(f"Low SKB paged fragments limit ({max_skb_frags} < 16); risks fragmentation allocation failures")
        recommendations.append("Restore net.core.max_skb_frags to default (17)")
    elif max_skb_frags > 64:
        issues.append(f"Elevated SKB paged fragments limit ({max_skb_frags} > 64); risks deep skb traversal overhead")
        recommendations.append("Clamp net.core.max_skb_frags to 17-64")

    if high_order_alloc_disable != 0 and high_order_alloc_disable != -1:
        issues.append(
            "Higher-order page allocations disabled for packet fragments (high_order_alloc_disable != 0); "
            "forces order-0 page thrashing and softirq overhead under heavy network throughput"
        )
        recommendations.append("Set net.core.high_order_alloc_disable to 0")

    if (unregister_timeout < 1 or unregister_timeout > 60) and unregister_timeout != -1:
        issues.append(f"Abnormal netdev unregister timeout ({unregister_timeout}s not in [1, 60]s range)")
        recommendations.append("Set net.core.netdev_unregister_timeout_secs to 10")

    if optmem_max < 4096 and optmem_max != -1:
        status = "CRITICAL"
    elif issues:
        status = "WARNING"

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": (status == "HEALTHY"),
        "optmem_max_bytes": optmem_max,
        "max_skb_frags": max_skb_frags,
        "high_order_alloc_disable": high_order_alloc_disable,
        "netdev_unregister_timeout_secs": unregister_timeout,
        "bpf_filter_headroom_ok": (optmem_max >= min_optmem_bytes),
        "higher_order_alloc_enabled": (high_order_alloc_disable == 0),
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network Core Socket Ancillary Buffer & SKB Page Fragment Guard (Pattern 276 / Pattern 414)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--conf-dir", default=PROC_CORE_DIR, help="Path to net core sysctl directory")
    parser.add_argument("--min-optmem", type=int, default=20480, help="Minimum optmem bytes threshold")
    parser.add_argument("--max-optmem", type=int, default=16777216, help="Maximum optmem bytes threshold")
    args = parser.parse_args()

    res = audit_optmem_guard(
        conf_dir=args.conf_dir,
        min_optmem_bytes=args.min_optmem,
        max_optmem_bytes=args.max_optmem,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        status_sym = "✓" if res["healthy"] else "✗"
        print(f"[{status_sym}] Core Socket Ancillary & SKB Fragment Guard: {res['status']}")
        print(f"    Optmem Max: {res['optmem_max_bytes']} B (BPF headroom ok: {res['bpf_filter_headroom_ok']})")
        print(f"    Max SKB Frags: {res['max_skb_frags']} | High-Order Alloc Disabled: {res['high_order_alloc_disable']}")
        print(f"    Netdev Unregister Timeout: {res['netdev_unregister_timeout_secs']}s")
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
