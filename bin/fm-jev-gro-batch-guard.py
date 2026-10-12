#!/usr/bin/env python3
"""
bin/fm-jev-gro-batch-guard.py - Host Network Generic Receive Offload (GRO) Batching, NAPI Weight Biases & Timestamp Policy Guard (Pattern 283 / Pattern 421)

Audits Linux kernel Generic Receive Offload (GRO) normal packet batching, NAPI RX/TX polling weight biases,
network packet timestamping policies, and kernel network warning message rate limiters:
  - /proc/sys/net/core/gro_normal_batch:
      Number of packets batched before delivery via netif_receive_skb_list (default 8).
  - /proc/sys/net/core/dev_weight_rx_bias:
      Scaling factor for RX NAPI polling weight (default 1).
  - /proc/sys/net/core/dev_weight_tx_bias:
      Scaling factor for TX NAPI polling weight (default 1).
  - /proc/sys/net/core/netdev_tstamp_prequeue:
      Software timestamping prequeue enablement (default 1).
  - /proc/sys/net/core/tstamp_allow_data:
      Allow payload data retention with SOF_TIMESTAMPING_OPT_TSONLY (default 1).
  - /proc/sys/net/core/message_burst:
      Token bucket burst for net core warnings (default 10).
  - /proc/sys/net/core/message_cost:
      Token replenishment interval in seconds for net core warnings (default 5).

Invariants:
  - gro_normal_batch must be >= 1 and <= 64 (default 8) to optimize stack throughput without tail latency spikes.
  - dev_weight_rx_bias and dev_weight_tx_bias must remain >= 1 and <= 16 to avoid starving RX or TX rings.
  - message_cost and message_burst must remain > 0 to prevent logging storms or division-by-zero errors.
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

PROC_NET_CORE_DIR = "/proc/sys/net/core"
PROC_SOFTNET_STAT = "/proc/net/softnet_stat"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content and (content.split()[0].lstrip("-").isdigit()) else default
    except (ValueError, OSError, IndexError):
        return default


def parse_softnet_stat(path: str) -> Dict[str, int]:
    if not os.path.isfile(path):
        return {}
    totals: Dict[str, int] = {
        "processed": 0,
        "dropped": 0,
        "time_squeeze": 0,
    }
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 3:
                    try:
                        totals["processed"] += int(parts[0], 16)
                        totals["dropped"] += int(parts[1], 16)
                        totals["time_squeeze"] += int(parts[2], 16)
                    except ValueError:
                        pass
        return totals
    except Exception:
        return totals


def audit_gro_batch_guard(
    core_dir: str = PROC_NET_CORE_DIR,
    softnet_file: str = PROC_SOFTNET_STAT,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    if not os.path.isdir(core_dir):
        return {
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "status": "UNKNOWN",
            "healthy": True,
            "core_dir": core_dir,
            "error": f"Net core sysctl directory not found at {core_dir}",
            "issues": [],
            "recommendations": [],
        }

    gro_normal_batch = read_sysctl_int(os.path.join(core_dir, "gro_normal_batch"), 8)
    rx_bias = read_sysctl_int(os.path.join(core_dir, "dev_weight_rx_bias"), 1)
    tx_bias = read_sysctl_int(os.path.join(core_dir, "dev_weight_tx_bias"), 1)
    tstamp_prequeue = read_sysctl_int(os.path.join(core_dir, "netdev_tstamp_prequeue"), 1)
    tstamp_allow_data = read_sysctl_int(os.path.join(core_dir, "tstamp_allow_data"), 1)
    msg_burst = read_sysctl_int(os.path.join(core_dir, "message_burst"), 10)
    msg_cost = read_sysctl_int(os.path.join(core_dir, "message_cost"), 5)

    softnet = parse_softnet_stat(softnet_file)

    if gro_normal_batch < 1 and gro_normal_batch != -1:
        issues.append(f"gro_normal_batch is disabled or invalid ({gro_normal_batch} < 1): disables GRO list reception")
        recommendations.append("Restore net.core.gro_normal_batch to default 8")
        status = "CRITICAL"
    elif gro_normal_batch > 64:
        issues.append(f"Excessively large gro_normal_batch ({gro_normal_batch} > 64): risks packet latency jitter")
        recommendations.append("Set net.core.gro_normal_batch between 8 and 32")
        status = "WARNING"

    if rx_bias < 1 and rx_bias != -1:
        issues.append(f"Invalid dev_weight_rx_bias ({rx_bias} < 1)")
        recommendations.append("Set net.core.dev_weight_rx_bias >= 1")
        status = "CRITICAL"
    elif rx_bias > 16:
        issues.append(f"Excessive dev_weight_rx_bias ({rx_bias} > 16): risks TX ring starvation")
        recommendations.append("Reduce net.core.dev_weight_rx_bias to <= 16")
        if status == "HEALTHY":
            status = "WARNING"

    if tx_bias < 1 and tx_bias != -1:
        issues.append(f"Invalid dev_weight_tx_bias ({tx_bias} < 1)")
        recommendations.append("Set net.core.dev_weight_tx_bias >= 1")
        status = "CRITICAL"
    elif tx_bias > 16:
        issues.append(f"Excessive dev_weight_tx_bias ({tx_bias} > 16): risks RX ring starvation")
        recommendations.append("Reduce net.core.dev_weight_tx_bias to <= 16")
        if status == "HEALTHY":
            status = "WARNING"

    if msg_cost <= 0 and msg_cost != -1:
        issues.append(f"Invalid message_cost ({msg_cost} <= 0): risks division-by-zero in printk rate limiter")
        recommendations.append("Set net.core.message_cost to default 5")
        status = "CRITICAL"

    if msg_burst <= 0 and msg_burst != -1:
        issues.append(f"Invalid message_burst ({msg_burst} <= 0): suppresses all network core error logging")
        recommendations.append("Set net.core.message_burst to default 10")
        if status == "HEALTHY":
            status = "WARNING"

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": (status == "HEALTHY"),
        "gro_normal_batch": gro_normal_batch,
        "dev_weight_rx_bias": rx_bias,
        "dev_weight_tx_bias": tx_bias,
        "netdev_tstamp_prequeue": tstamp_prequeue,
        "tstamp_allow_data": tstamp_allow_data,
        "message_burst": msg_burst,
        "message_cost": msg_cost,
        "softnet_processed": softnet.get("processed", 0),
        "softnet_dropped": softnet.get("dropped", 0),
        "softnet_time_squeeze": softnet.get("time_squeeze", 0),
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network Generic Receive Offload (GRO) Batching, NAPI Weight Biases & Timestamp Policy Guard (Pattern 283 / Pattern 421)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--core-dir", default=PROC_NET_CORE_DIR, help="Path to net core sysctl directory")
    parser.add_argument("--softnet-file", default=PROC_SOFTNET_STAT, help="Path to /proc/net/softnet_stat")
    args = parser.parse_args()

    res = audit_gro_batch_guard(
        core_dir=args.core_dir,
        softnet_file=args.softnet_file,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        status_sym = "✓" if res["healthy"] else "✗"
        print(f"[{status_sym}] GRO Batching & Core Policy Guard: {res['status']}")
        print(f"    GRO Batching: gro_normal_batch={res.get('gro_normal_batch', 0)} | rx_bias={res.get('dev_weight_rx_bias', 0)} | tx_bias={res.get('dev_weight_tx_bias', 0)}")
        print(f"    Timestamping: tstamp_prequeue={res.get('netdev_tstamp_prequeue', 0)} | tstamp_allow_data={res.get('tstamp_allow_data', 0)}")
        print(f"    Message Limits: message_burst={res.get('message_burst', 0)} | message_cost={res.get('message_cost', 0)}s")
        print(f"    Softnet Stats: processed={res.get('softnet_processed', 0)} | dropped={res.get('softnet_dropped', 0)} | time_squeeze={res.get('softnet_time_squeeze', 0)}")
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
