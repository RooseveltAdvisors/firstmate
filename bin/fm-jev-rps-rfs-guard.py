#!/usr/bin/env python3
"""
bin/fm-jev-rps-rfs-guard.py - Linux Network RPS, RFS & GRO Normal Batch Guard (Pattern 306 / Pattern 444)

Audits Linux kernel Receive Packet Steering (RPS), Receive Flow Steering (RFS), and Generic
Receive Offload (GRO) batching configuration and softirq telemetry:
  - /proc/sys/net/core/rps_sock_flow_entries: Global RFS socket flow table entries (power-of-2 required)
  - /proc/sys/net/core/rps_default_mask: Default CPU mask for RPS on dynamically created virtual devices
  - /proc/sys/net/core/flow_limit_cpu_bitmap: CPU bitmap enabling flow limits for elephant flows
  - /proc/sys/net/core/gro_normal_batch: Maximum number of unmerged packets GRO passes to network stack
  - /proc/sys/net/core/netdev_tstamp_prequeue: Prequeue device timestamping flag
  - /proc/net/softnet_stat: Per-CPU RPS packet steering and flow limit encounter counts
  - /sys/class/net/*/queues/rx-*: Per-device RX queue RPS CPU masks and RFS flow counts

Invariants:
  - gro_normal_batch must be positive (> 0, standard default 8).
  - rps_sock_flow_entries if enabled must be a power of 2 to avoid kernel hash table skewing.
  - Per-CPU softnet flow_limit_count must remain within safe operational bounds.
  - Fail-open: graceful degradation when sysfs/sysctl paths are restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List

SYSCTL_RPS_SOCK_FLOW = "/proc/sys/net/core/rps_sock_flow_entries"
SYSCTL_RPS_DEFAULT_MASK = "/proc/sys/net/core/rps_default_mask"
SYSCTL_FLOW_LIMIT_CPU = "/proc/sys/net/core/flow_limit_cpu_bitmap"
SYSCTL_GRO_NORMAL_BATCH = "/proc/sys/net/core/gro_normal_batch"
SYSCTL_NETDEV_TSTAMP_PREQUEUE = "/proc/sys/net/core/netdev_tstamp_prequeue"
PROC_SOFTNET_STAT = "/proc/net/softnet_stat"
SYSFS_NET_DIR = "/sys/class/net"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        parts = content.split()
        return int(parts[0]) if parts and parts[0].lstrip("-").isdigit() else default
    except (ValueError, OSError, IndexError):
        return default


def read_sysctl_str(path: str, default: str = "") -> str:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return default


def parse_softnet_rps(path: str) -> Dict[str, int]:
    res = {
        "received_rps": 0,
        "flow_limit_count": 0,
        "cpu_count": 0,
    }
    if not os.path.isfile(path):
        return res
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        res["cpu_count"] = len(lines)
        for line in lines:
            parts = line.split()
            # Column 4 (0-indexed 4): received_rps
            # Column 5 (0-indexed 5): flow_limit_count
            if len(parts) >= 6:
                try:
                    res["received_rps"] += int(parts[4], 16)
                    res["flow_limit_count"] += int(parts[5], 16)
                except ValueError:
                    pass
    except OSError:
        pass
    return res


def scan_rx_queues(net_dir: str) -> Dict[str, Any]:
    stats = {
        "total_rx_queues": 0,
        "rps_active_queues": 0,
        "rfs_active_queues": 0,
        "devices_scanned": 0,
    }
    net_path = Path(net_dir)
    if not net_path.is_dir():
        return stats

    try:
        for dev_path in net_path.iterdir():
            if not dev_path.is_dir():
                continue
            stats["devices_scanned"] += 1
            queues_dir = dev_path / "queues"
            if not queues_dir.is_dir():
                continue

            for rx_dir in queues_dir.glob("rx-*"):
                if not rx_dir.is_dir():
                    continue
                stats["total_rx_queues"] += 1

                rps_cpus_file = rx_dir / "rps_cpus"
                if rps_cpus_file.is_file():
                    try:
                        mask = rps_cpus_file.read_text().strip()
                        if mask and mask.replace("0", "").replace(",", ""):
                            stats["rps_active_queues"] += 1
                    except OSError:
                        pass

                rps_flow_file = rx_dir / "rps_flow_cnt"
                if rps_flow_file.is_file():
                    try:
                        cnt = int(rps_flow_file.read_text().strip())
                        if cnt > 0:
                            stats["rfs_active_queues"] += 1
                    except (ValueError, OSError):
                        pass
    except OSError:
        pass

    return stats


def evaluate_rps_rfs(
    rps_sock_flow_file: str = SYSCTL_RPS_SOCK_FLOW,
    rps_default_mask_file: str = SYSCTL_RPS_DEFAULT_MASK,
    flow_limit_cpu_file: str = SYSCTL_FLOW_LIMIT_CPU,
    gro_normal_batch_file: str = SYSCTL_GRO_NORMAL_BATCH,
    netdev_tstamp_prequeue_file: str = SYSCTL_NETDEV_TSTAMP_PREQUEUE,
    softnet_stat_file: str = PROC_SOFTNET_STAT,
    sysfs_net_dir: str = SYSFS_NET_DIR,
    warn_flow_limit: int = 100,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    rps_sock_flow = read_sysctl_int(rps_sock_flow_file)
    rps_default_mask = read_sysctl_str(rps_default_mask_file)
    flow_limit_cpu = read_sysctl_str(flow_limit_cpu_file)
    gro_normal_batch = read_sysctl_int(gro_normal_batch_file)
    netdev_tstamp = read_sysctl_int(netdev_tstamp_prequeue_file)

    softnet = parse_softnet_rps(softnet_stat_file)
    rx_stats = scan_rx_queues(sysfs_net_dir)

    if gro_normal_batch <= 0:
        issues.append(
            f"Invalid GRO normal batch size ({gro_normal_batch}); GRO unmerged packet flushing disabled or corrupted"
        )
        recommendations.append("Set sysctl net.core.gro_normal_batch to default 8")
        status = "WARNING"

    if softnet["flow_limit_count"] >= warn_flow_limit:
        issues.append(
            f"Elevated softnet flow limit count ({softnet['flow_limit_count']}); single high-rate flows saturating softirq backlog"
        )
        recommendations.append("Check active elephant flows and consider increasing softirq budget or netdev_max_backlog")
        if status != "CRITICAL":
            status = "WARNING"

    if rps_sock_flow > 0 and (rps_sock_flow & (rps_sock_flow - 1)) != 0:
        issues.append(
            f"rps_sock_flow_entries ({rps_sock_flow}) is not a power of 2; kernel hash table rounding may cause uneven distribution"
        )
        recommendations.append("Set net.core.rps_sock_flow_entries to a power of 2 (e.g., 32768)")
        if status != "CRITICAL":
            status = "WARNING"

    healthy = len(issues) == 0

    return {
        "pattern": 306,
        "name": "rps_rfs",
        "description": "Linux Network Receive Packet Steering (RPS), Receive Flow Steering (RFS) & GRO Normal Batch Guard",
        "status": status,
        "healthy": healthy,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "rps_sock_flow_entries": rps_sock_flow,
        "rps_default_mask": rps_default_mask,
        "flow_limit_cpu_bitmap": flow_limit_cpu,
        "gro_normal_batch": gro_normal_batch,
        "netdev_tstamp_prequeue": netdev_tstamp,
        "received_rps": softnet["received_rps"],
        "flow_limit_count": softnet["flow_limit_count"],
        "cpu_count": softnet["cpu_count"],
        "total_rx_queues": rx_stats["total_rx_queues"],
        "rps_active_queues": rx_stats["rps_active_queues"],
        "rfs_active_queues": rx_stats["rfs_active_queues"],
        "devices_scanned": rx_stats["devices_scanned"],
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Linux Network RPS, RFS & GRO Normal Batch Guard (Pattern 306 / Pattern 444)"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--rps-sock-flow-file", default=SYSCTL_RPS_SOCK_FLOW, help="Path to rps_sock_flow_entries sysctl")
    parser.add_argument("--rps-default-mask-file", default=SYSCTL_RPS_DEFAULT_MASK, help="Path to rps_default_mask sysctl")
    parser.add_argument("--flow-limit-cpu-file", default=SYSCTL_FLOW_LIMIT_CPU, help="Path to flow_limit_cpu_bitmap sysctl")
    parser.add_argument("--gro-normal-batch-file", default=SYSCTL_GRO_NORMAL_BATCH, help="Path to gro_normal_batch sysctl")
    parser.add_argument("--netdev-tstamp-prequeue-file", default=SYSCTL_NETDEV_TSTAMP_PREQUEUE, help="Path to netdev_tstamp_prequeue sysctl")
    parser.add_argument("--softnet-stat-file", default=PROC_SOFTNET_STAT, help="Path to /proc/net/softnet_stat")
    parser.add_argument("--sysfs-net-dir", default=SYSFS_NET_DIR, help="Path to /sys/class/net")
    parser.add_argument("--warn-flow-limit", type=int, default=100, help="Warning threshold for softnet flow_limit_count")
    args = parser.parse_args()

    result = evaluate_rps_rfs(
        rps_sock_flow_file=args.rps_sock_flow_file,
        rps_default_mask_file=args.rps_default_mask_file,
        flow_limit_cpu_file=args.flow_limit_cpu_file,
        gro_normal_batch_file=args.gro_normal_batch_file,
        netdev_tstamp_prequeue_file=args.netdev_tstamp_prequeue_file,
        softnet_stat_file=args.softnet_stat_file,
        sysfs_net_dir=args.sysfs_net_dir,
        warn_flow_limit=args.warn_flow_limit,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] Pattern {result['pattern']} - {result['description']}")
        print(f"  RPS Sock Flow Entries: {result['rps_sock_flow_entries']}, GRO Normal Batch: {result['gro_normal_batch']}")
        print(f"  RPS Default Mask: '{result['rps_default_mask']}', Flow Limit CPU Bitmap: '{result['flow_limit_cpu_bitmap']}'")
        print(f"  Prequeue Tstamp: {result['netdev_tstamp_prequeue']}, Softnet CPUs: {result['cpu_count']}")
        print(f"  Softnet Received RPS: {result['received_rps']}, Flow Limit Count: {result['flow_limit_count']}")
        print(f"  Devices Scanned: {result['devices_scanned']}, RX Queues: {result['total_rx_queues']} (RPS Active: {result['rps_active_queues']}, RFS Active: {result['rfs_active_queues']})")
        if result["issues"]:
            print("  Issues:")
            for issue in result["issues"]:
                print(f"    - {issue}")
        if result["recommendations"]:
            print("  Recommendations:")
            for rec in result["recommendations"]:
                print(f"    - {rec}")

    if not result["healthy"]:
        sys.exit(1 if result["status"] == "WARNING" else 2)


if __name__ == "__main__":
    main()
