#!/usr/bin/env python3
"""
bin/fm-jev-psched-guard.py - Host Network Packet Scheduler Clock Calibration & Qdisc Timing Guard (Pattern 241)

Audits Linux kernel packet scheduler clock calibration constants and traffic control timing from:
  - /proc/net/psched (psched_tick_per_us, psched_us_per_tick, psched_clock_res, psched_clock_scale)
  - /proc/sys/net/core/default_qdisc (default packet queuing discipline, e.g. fq_codel, fq, cake)
  - /sys/class/net/<iface>/tx_queue_len (interface transmit queue length)

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

DEFAULT_PSCHED_PATH = "/proc/net/psched"
DEFAULT_SYS_CORE_PATH = "/proc/sys/net/core"
DEFAULT_SYS_NET_PATH = "/sys/class/net"

EXPECTED_CLOCK_RES_MIN = 1_000_000        # At least 1 MHz resolution
EXPECTED_CLOCK_SCALE_MIN = 1_000_000_000  # At least 1 GHz scale


def read_sysctl_str(path: str, default: str = "") -> str:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return default


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception:
        return default


def parse_proc_net_psched(path: str = DEFAULT_PSCHED_PATH) -> Dict[str, int]:
    keys = [
        "tick_per_us",
        "us_per_tick",
        "clock_res_hz",
        "clock_scale",
    ]
    result: Dict[str, int] = {k: 0 for k in keys}
    if not os.path.exists(path):
        return result

    try:
        with open(path, "r", encoding="utf-8") as f:
            parts = f.read().strip().split()
        for k, v_hex in zip(keys, parts):
            try:
                result[k] = int(v_hex, 16)
            except ValueError:
                continue
    except Exception:
        pass

    return result


def parse_tx_queue_lens(sys_net_path: str = DEFAULT_SYS_NET_PATH) -> Dict[str, int]:
    interfaces: Dict[str, int] = {}
    if not os.path.isdir(sys_net_path):
        return interfaces

    try:
        for name in sorted(os.listdir(sys_net_path)):
            iface_dir = os.path.join(sys_net_path, name)
            if not os.path.isdir(iface_dir):
                continue
            qlen_path = os.path.join(iface_dir, "tx_queue_len")
            if os.path.exists(qlen_path):
                qlen = read_sysctl_int(qlen_path, default=0)
                interfaces[name] = qlen
    except Exception:
        pass

    return interfaces


def audit_psched(
    psched_path: str = DEFAULT_PSCHED_PATH,
    sys_core_path: str = DEFAULT_SYS_CORE_PATH,
    sys_net_path: str = DEFAULT_SYS_NET_PATH,
) -> Dict[str, Any]:
    psched = parse_proc_net_psched(psched_path)
    default_qdisc = read_sysctl_str(
        os.path.join(sys_core_path, "default_qdisc"), default="unknown"
    )
    tx_queue_lens = parse_tx_queue_lens(sys_net_path)

    issues: List[str] = []
    recommendations: List[str] = []

    clock_res = psched.get("clock_res_hz", 0)
    clock_scale = psched.get("clock_scale", 0)
    tick_per_us = psched.get("tick_per_us", 0)

    if clock_res < EXPECTED_CLOCK_RES_MIN and clock_res > 0:
        issues.append(
            f"Degraded packet scheduler clock resolution ({clock_res} Hz < {EXPECTED_CLOCK_RES_MIN} Hz); "
            "microsecond traffic pacing accuracy compromised"
        )
        recommendations.append("Ensure high-resolution kernel timers (CONFIG_HIGH_RES_TIMERS) are active")

    if clock_scale < EXPECTED_CLOCK_SCALE_MIN and clock_scale > 0:
        issues.append(
            f"Suboptimal packet scheduler clock scale ({clock_scale} < {EXPECTED_CLOCK_SCALE_MIN}); "
            "risk of qdisc timer drift under heavy rate limiting"
        )
        recommendations.append("Verify TSC/APIC clocksource calibration")

    if tick_per_us == 0 and clock_res == 0:
        issues.append("Unable to parse packet scheduler calibration constants from /proc/net/psched")
        recommendations.append("Verify /proc/net/psched availability")

    if default_qdisc in ("pfifo_fast", "unknown"):
        recommendations.append(
            f"Consider migrating default_qdisc from '{default_qdisc}' to 'fq_codel', 'fq', or 'cake' for latency reduction"
        )

    if issues:
        status = "WARNING"
        recommendation_str = "; ".join(recommendations)
    else:
        status = "HEALTHY"
        recommendation_str = (
            "Packet scheduler clock calibration (1 MHz / 1 GHz scale) and queue timing are nominal"
        )

    summary = {
        "status": status,
        "healthy": (status == "HEALTHY"),
        "tick_per_us": tick_per_us,
        "us_per_tick": psched.get("us_per_tick", 0),
        "clock_res_hz": clock_res,
        "clock_scale": clock_scale,
        "default_qdisc": default_qdisc,
        "interfaces_count": len(tx_queue_lens),
        "issues": issues,
        "recommendation": recommendation_str,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "psched": psched,
        "default_qdisc": default_qdisc,
        "tx_queue_lens": tx_queue_lens,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network Packet Scheduler Clock Calibration & Qdisc Timing Guard (Pattern 241)"
    )
    parser.add_argument("--json", action="store_true", help="Output machine-readable JSON")
    parser.add_argument(
        "--psched", default=DEFAULT_PSCHED_PATH, help="Path to /proc/net/psched file"
    )
    parser.add_argument(
        "--sys-core", default=DEFAULT_SYS_CORE_PATH, help="Path to /proc/sys/net/core directory"
    )
    parser.add_argument(
        "--sys-net", default=DEFAULT_SYS_NET_PATH, help="Path to /sys/class/net directory"
    )
    args = parser.parse_args()

    report = audit_psched(
        psched_path=args.psched,
        sys_core_path=args.sys_core,
        sys_net_path=args.sys_net,
    )

    s = report["summary"]
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(
            f"[{s['status']}] Jev Psched Guard: clock_res={s['clock_res_hz']:,} Hz, "
            f"clock_scale={s['clock_scale']:,}, tick_per_us={s['tick_per_us']}, "
            f"default_qdisc='{s['default_qdisc']}', {s['interfaces_count']} interfaces"
        )
        for iface, qlen in report["tx_queue_lens"].items():
            print(f"    - {iface}: tx_queue_len={qlen}")
        if s["issues"]:
            print("  Issues:")
            for iss in s["issues"]:
                print(f"    - {iss}")
        print(f"  Recommendation: {s['recommendation']}")

    return 0 if s["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
