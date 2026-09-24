#!/usr/bin/env python3
"""
bin/fm-jev-napi-defer-guard.py - Host Network NAPI Hard IRQ Deferral & GRO Flush Timeout Guard (Pattern 240)

Audits Linux kernel NAPI busy-polling hard IRQ deferral parameters, GRO batching,
and interrupt budget policies from:
  - /sys/class/net/<iface>/napi_defer_hard_irqs (per-interface NAPI deferral cycle count)
  - /sys/class/net/<iface>/gro_flush_timeout (maximum GRO packet hold time in nanoseconds)
  - /sys/class/net/<iface>/threaded (threaded NAPI polling mode)
  - /proc/sys/net/core/gro_normal_batch (consecutive packet batching threshold)
  - /proc/sys/net/core/dev_weight (per-NAPI polling budget)
  - /proc/sys/net/core/netdev_budget (aggregate softirq budget across all NAPI devices)
  - /proc/sys/net/core/netdev_budget_usecs (maximum softirq processing time in microseconds)

Ensures low-latency packet processing without excessive IRQ suppression delays,
GRO packet stalls, or softirq execution overruns across multi-agent RPC endpoints.

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
from typing import Any, Dict, List, Tuple

DEFAULT_SYS_NET_PATH = "/sys/class/net"
DEFAULT_SYS_CORE_PATH = "/proc/sys/net/core"

WARN_MAX_DEFER_HARD_IRQS = 10
WARN_MAX_GRO_FLUSH_TIMEOUT_NS = 200_000  # 200 microseconds
WARN_MIN_GRO_NORMAL_BATCH = 1
WARN_MIN_DEV_WEIGHT = 16
WARN_MIN_NETDEV_BUDGET = 100
WARN_MIN_NETDEV_BUDGET_USECS = 1000


def read_sysfs_int(path: str, default: int = -1) -> int:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception:
        return default


def read_sysfs_str(path: str, default: str = "") -> str:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return default


def parse_interface_napi(
    sys_net_path: str = DEFAULT_SYS_NET_PATH,
) -> Dict[str, Dict[str, Any]]:
    interfaces: Dict[str, Dict[str, Any]] = {}
    if not os.path.isdir(sys_net_path):
        return interfaces

    try:
        for name in sorted(os.listdir(sys_net_path)):
            iface_dir = os.path.join(sys_net_path, name)
            if not os.path.isdir(iface_dir):
                continue
            defer_path = os.path.join(iface_dir, "napi_defer_hard_irqs")
            flush_path = os.path.join(iface_dir, "gro_flush_timeout")
            threaded_path = os.path.join(iface_dir, "threaded")
            operstate_path = os.path.join(iface_dir, "operstate")

            defer_val = read_sysfs_int(defer_path, default=0)
            flush_val = read_sysfs_int(flush_path, default=0)
            threaded_val = read_sysfs_int(threaded_path, default=0)
            operstate_val = read_sysfs_str(operstate_path, default="unknown")

            interfaces[name] = {
                "napi_defer_hard_irqs": defer_val,
                "gro_flush_timeout_ns": flush_val,
                "threaded": threaded_val,
                "operstate": operstate_val,
            }
    except Exception:
        pass

    return interfaces


def parse_core_napi_sysctls(
    sys_core_path: str = DEFAULT_SYS_CORE_PATH,
) -> Dict[str, int]:
    return {
        "gro_normal_batch": read_sysfs_int(os.path.join(sys_core_path, "gro_normal_batch"), default=8),
        "dev_weight": read_sysfs_int(os.path.join(sys_core_path, "dev_weight"), default=64),
        "dev_weight_rx_bias": read_sysfs_int(os.path.join(sys_core_path, "dev_weight_rx_bias"), default=1),
        "dev_weight_tx_bias": read_sysfs_int(os.path.join(sys_core_path, "dev_weight_tx_bias"), default=1),
        "netdev_budget": read_sysfs_int(os.path.join(sys_core_path, "netdev_budget"), default=300),
        "netdev_budget_usecs": read_sysfs_int(os.path.join(sys_core_path, "netdev_budget_usecs"), default=2000),
        "busy_poll": read_sysfs_int(os.path.join(sys_core_path, "busy_poll"), default=0),
        "busy_read": read_sysfs_int(os.path.join(sys_core_path, "busy_read"), default=0),
    }


def audit_napi_defer(
    sys_net_path: str = DEFAULT_SYS_NET_PATH,
    sys_core_path: str = DEFAULT_SYS_CORE_PATH,
    warn_max_defer: int = WARN_MAX_DEFER_HARD_IRQS,
    warn_max_flush_ns: int = WARN_MAX_GRO_FLUSH_TIMEOUT_NS,
) -> Dict[str, Any]:
    interfaces = parse_interface_napi(sys_net_path)
    core_sysctls = parse_core_napi_sysctls(sys_core_path)

    issues: List[str] = []
    recommendations: List[str] = []

    total_interfaces = len(interfaces)
    up_interfaces = sum(1 for v in interfaces.values() if v.get("operstate") == "up")
    deferred_interfaces: List[str] = []

    for iface_name, params in interfaces.items():
        defer = params.get("napi_defer_hard_irqs", 0)
        flush_ns = params.get("gro_flush_timeout_ns", 0)

        if defer > 0 or flush_ns > 0:
            deferred_interfaces.append(iface_name)

        if defer > warn_max_defer:
            issues.append(
                f"Interface {iface_name}: napi_defer_hard_irqs={defer} exceeds limit {warn_max_defer}; "
                "excessive hard IRQ suppression risks packet delivery stalls"
            )
            recommendations.append(
                f"Tune /sys/class/net/{iface_name}/napi_defer_hard_irqs to <= {warn_max_defer}"
            )

        if flush_ns > warn_max_flush_ns:
            issues.append(
                f"Interface {iface_name}: gro_flush_timeout={flush_ns}ns exceeds limit {warn_max_flush_ns}ns; "
                "excessive GRO packet aggregation hold time induces latency jitter"
            )
            recommendations.append(
                f"Tune /sys/class/net/{iface_name}/gro_flush_timeout to <= {warn_max_flush_ns}ns"
            )

    gro_normal_batch = core_sysctls.get("gro_normal_batch", 8)
    if gro_normal_batch < WARN_MIN_GRO_NORMAL_BATCH:
        issues.append(
            f"net.core.gro_normal_batch={gro_normal_batch} below minimum {WARN_MIN_GRO_NORMAL_BATCH}; "
            "GRO batch flushing disabled"
        )
        recommendations.append("Set sysctl -w net.core.gro_normal_batch=8")

    dev_weight = core_sysctls.get("dev_weight", 64)
    if dev_weight < WARN_MIN_DEV_WEIGHT:
        issues.append(
            f"net.core.dev_weight={dev_weight} below minimum {WARN_MIN_DEV_WEIGHT}; "
            "NAPI polling quota severely constrained"
        )
        recommendations.append("Set sysctl -w net.core.dev_weight=64")

    netdev_budget = core_sysctls.get("netdev_budget", 300)
    if netdev_budget < WARN_MIN_NETDEV_BUDGET:
        issues.append(
            f"net.core.netdev_budget={netdev_budget} below minimum {WARN_MIN_NETDEV_BUDGET}; "
            "softirq packet processing starvation risk"
        )
        recommendations.append("Set sysctl -w net.core.netdev_budget=300")

    if issues:
        status = "WARNING"
        recommendation_str = "; ".join(recommendations)
    else:
        status = "HEALTHY"
        recommendation_str = (
            "NAPI hard IRQ deferral cycles, GRO flush timeouts, and kernel softirq budgets are nominal"
        )

    summary = {
        "status": status,
        "healthy": (status == "HEALTHY"),
        "total_interfaces": total_interfaces,
        "up_interfaces": up_interfaces,
        "deferred_interfaces_count": len(deferred_interfaces),
        "deferred_interfaces": deferred_interfaces,
        "gro_normal_batch": gro_normal_batch,
        "dev_weight": dev_weight,
        "netdev_budget": netdev_budget,
        "netdev_budget_usecs": core_sysctls.get("netdev_budget_usecs", 2000),
        "issues": issues,
        "recommendation": recommendation_str,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "interfaces": interfaces,
        "core_sysctls": core_sysctls,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network NAPI Hard IRQ Deferral & GRO Flush Timeout Guard (Pattern 240)"
    )
    parser.add_argument("--json", action="store_true", help="Output machine-readable JSON")
    parser.add_argument(
        "--sys-net", default=DEFAULT_SYS_NET_PATH, help="Path to /sys/class/net directory"
    )
    parser.add_argument(
        "--sys-core", default=DEFAULT_SYS_CORE_PATH, help="Path to /proc/sys/net/core directory"
    )
    args = parser.parse_args()

    report = audit_napi_defer(
        sys_net_path=args.sys_net,
        sys_core_path=args.sys_core,
    )

    s = report["summary"]
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(
            f"[{s['status']}] Jev Napi Defer Guard: {s['total_interfaces']} interfaces "
            f"({s['up_interfaces']} up, {s['deferred_interfaces_count']} with active deferral), "
            f"gro_normal_batch={s['gro_normal_batch']}, dev_weight={s['dev_weight']}, "
            f"netdev_budget={s['netdev_budget']} ({s['netdev_budget_usecs']}us)"
        )
        if s["deferred_interfaces"]:
            print(f"  Deferred interfaces: {', '.join(s['deferred_interfaces'])}")
        for iface, p in report["interfaces"].items():
            if p["napi_defer_hard_irqs"] > 0 or p["gro_flush_timeout_ns"] > 0:
                print(
                    f"    - {iface}: defer={p['napi_defer_hard_irqs']} cycles, "
                    f"gro_flush={p['gro_flush_timeout_ns']}ns, threaded={p['threaded']}, "
                    f"operstate={p['operstate']}"
                )
        if s["issues"]:
            print("  Issues:")
            for iss in s["issues"]:
                print(f"    - {iss}")
        print(f"  Recommendation: {s['recommendation']}")

    return 0 if s["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
