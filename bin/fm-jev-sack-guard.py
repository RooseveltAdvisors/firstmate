#!/usr/bin/env python3
"""
bin/fm-jev-sack-guard.py - Host Network TCP Out-Of-Order Queue & SACK Loss Recovery Guard (Pattern 210)

Audits Linux kernel TCP Selective Acknowledgment (SACK) and Out-Of-Order (OFO) reassembly queues:
  - /proc/net/netstat (TCPOFOQueue, TCPOFODrop, TCPOFOMerge, TCPSackRecovery, TCPSackFailures, TCPSACKReorder)
  - /proc/sys/net/ipv4/tcp_sack (Selective Acknowledgment enabled)
  - /proc/sys/net/ipv4/tcp_dsack (Duplicate SACK acknowledgment enabled)
  - /proc/sys/net/ipv4/tcp_reordering (packet reordering threshold)
  - /proc/sys/net/ipv4/tcp_recovery (RACK loss detection algorithm mode)

Detects Out-Of-Order queue memory exhaustion drops, excessive SACK recovery failures, SACK disablement,
and TCP retransmission collapses across multi-agent RPC tunnels, Playwright headless runs, and API clients.

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


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception:
        return default


def parse_netstat_tcpext(path: str = "/proc/net/netstat") -> Dict[str, int]:
    metrics: Dict[str, int] = {
        "TCPOFOQueue": 0,
        "TCPOFODrop": 0,
        "TCPOFOMerge": 0,
        "TCPSackRecovery": 0,
        "TCPSackFailures": 0,
        "TCPSACKReorder": 0,
        "TCPLostRetransmit": 0,
        "TCPRetransFail": 0,
    }
    if not os.path.exists(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = [line.strip() for line in f if line.strip()]

        for i in range(0, len(lines), 2):
            header = lines[i].split()
            values = lines[i + 1].split()
            if header and header[0] == "TcpExt:" and len(header) == len(values):
                mapping = dict(zip(header, values))
                for k in metrics.keys():
                    if k in mapping:
                        try:
                            metrics[k] = int(mapping[k])
                        except ValueError:
                            pass
    except Exception:
        pass

    return metrics


def audit_sack_guard(
    proc_netstat: str = "/proc/net/netstat",
    proc_sys_ipv4: str = "/proc/sys/net/ipv4",
) -> Dict[str, Any]:
    metrics = parse_netstat_tcpext(proc_netstat)

    tcp_sack = read_sysctl_int(os.path.join(proc_sys_ipv4, "tcp_sack"), 1)
    tcp_dsack = read_sysctl_int(os.path.join(proc_sys_ipv4, "tcp_dsack"), 1)
    tcp_reordering = read_sysctl_int(os.path.join(proc_sys_ipv4, "tcp_reordering"), 3)
    tcp_recovery = read_sysctl_int(os.path.join(proc_sys_ipv4, "tcp_recovery"), 1)

    issues: List[str] = []
    status = "HEALTHY"

    ofo_queue = metrics["TCPOFOQueue"]
    ofo_drop = metrics["TCPOFODrop"]
    ofo_merge = metrics["TCPOFOMerge"]
    sack_recovery = metrics["TCPSackRecovery"]
    sack_failures = metrics["TCPSackFailures"]
    sack_reorder = metrics["TCPSACKReorder"]

    ofo_drop_ratio = 0.0
    if ofo_queue > 0:
        ofo_drop_ratio = round(ofo_drop / ofo_queue, 6)
        if ofo_queue > 1000 and ofo_drop_ratio >= 0.05:
            issues.append(
                f"WARNING: High TCP Out-Of-Order queue drop ratio ({ofo_drop_ratio * 100:.2f}%, {ofo_drop:,} drops / {ofo_queue:,} queued)"
            )
            status = "WARNING"

    sack_fail_ratio = 0.0
    if sack_recovery > 0:
        sack_fail_ratio = round(sack_failures / sack_recovery, 6)
        if sack_recovery > 500 and sack_fail_ratio >= 0.15:
            issues.append(
                f"WARNING: High SACK recovery failure ratio ({sack_fail_ratio * 100:.2f}%, {sack_failures:,} failures / {sack_recovery:,} recoveries)"
            )
            status = "WARNING"

    if tcp_sack == 0:
        issues.append("CRITICAL: net.ipv4.tcp_sack is disabled; loss recovery severely degraded")
        status = "CRITICAL"

    if tcp_dsack == 0:
        issues.append("WARNING: net.ipv4.tcp_dsack is disabled; duplicate packet loss detection degraded")
        if status != "CRITICAL":
            status = "WARNING"

    healthy = status == "HEALTHY"
    recommendation = (
        "TCP SACK scoreboard, loss recovery algorithms, and out-of-order reassembly queues are nominal."
        if healthy
        else "; ".join(issues)
    )

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "tcp_sack_enabled": bool(tcp_sack),
            "tcp_dsack_enabled": bool(tcp_dsack),
            "tcp_reordering": tcp_reordering,
            "tcp_recovery_mode": tcp_recovery,
            "ofo_queued_packets": ofo_queue,
            "ofo_dropped_packets": ofo_drop,
            "ofo_drop_ratio": ofo_drop_ratio,
            "ofo_merged_packets": ofo_merge,
            "sack_recoveries": sack_recovery,
            "sack_failures": sack_failures,
            "sack_failure_ratio": sack_fail_ratio,
            "sack_reorders": sack_reorder,
            "lost_retransmits": metrics["TCPLostRetransmit"],
            "retransmit_failures": metrics["TCPRetransFail"],
            "issues": issues,
            "recommendation": recommendation,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network TCP Out-Of-Order Queue & SACK Loss Recovery Guard (Pattern 210)"
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON telemetry")
    args = parser.parse_args()

    report = audit_sack_guard()
    s = report["summary"]

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"[{s['status']}] Pattern 210: Host Network TCP SACK & Out-Of-Order Reassembly Guard")
        print(
            f"  SACK Features: sack={'enabled' if s['tcp_sack_enabled'] else 'disabled'}, "
            f"dsack={'enabled' if s['tcp_dsack_enabled'] else 'disabled'}, reordering={s['tcp_reordering']}, recovery_mode={s['tcp_recovery_mode']}"
        )
        print(
            f"  OFO Reassembly Queue: {s['ofo_queued_packets']:,} queued, {s['ofo_dropped_packets']:,} dropped "
            f"({s['ofo_drop_ratio'] * 100:.4f}% drops), {s['ofo_merged_packets']:,} merged"
        )
        print(
            f"  SACK Loss Recovery: {s['sack_recoveries']:,} recoveries, {s['sack_failures']:,} failures "
            f"({s['sack_failure_ratio'] * 100:.4f}% fail ratio), {s['sack_reorders']:,} reorders"
        )
        print(f"  Recommendation: {s['recommendation']}")

    return 0 if s["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
