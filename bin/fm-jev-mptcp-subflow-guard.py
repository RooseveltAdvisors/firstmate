#!/usr/bin/env python3
"""
bin/fm-jev-mptcp-subflow-guard.py - Linux MPTCP Subflow Scheduler & Stale Loss Guard (Pattern 304 / Pattern 442)

Audits Linux kernel Multipath TCP (MPTCP RFC 8684) subflow packet scheduler selection,
path manager registration, stale loss recovery thresholds, and middlebox fallback telemetry:
  - /proc/sys/net/mptcp/enabled: Master enable flag for MPTCP protocol (1=enabled, 0=disabled)
  - /proc/sys/net/mptcp/path_manager: Active path manager (e.g. 'kernel', 'userspace')
  - /proc/sys/net/mptcp/available_path_managers: Supported path managers
  - /proc/sys/net/mptcp/scheduler: Active packet scheduler (e.g. 'default')
  - /proc/sys/net/mptcp/available_schedulers: Supported packet schedulers
  - /proc/sys/net/mptcp/stale_loss_cnt: Consecutive retransmissions before marking subflow stale (default 4)
  - /proc/sys/net/mptcp/syn_retrans_before_tcp_fallback: SYN retransmissions before fallback to standard TCP (default 2)
  - /proc/net/netstat (MPTcpExt): MPCurrEstab, SubflowStale, SubflowRecover, FallbackFailed, DSSCorruptionReset

Invariants:
  - MPTCP must be enabled (net.mptcp.enabled=1).
  - Path manager must be registered in available_path_managers.
  - Subflow scheduler must be registered in available_schedulers.
  - stale_loss_cnt must be within nominal range [1, 16] (default 4).
  - syn_retrans_before_tcp_fallback must be within nominal range [1, 10] (default 2).
  - Zero FallbackFailed and zero DSSCorruptionReset events.
  - Fail-open: graceful fallback when sysctl paths or /proc/net/netstat are restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

PROC_MPTCP_DIR = "/proc/sys/net/mptcp"
PROC_NETSTAT = "/proc/net/netstat"


def read_sysctl_str(path: str, default: str = "") -> str:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except (OSError, UnicodeDecodeError):
        return default


def read_sysctl_int(path: str, default: int = -1) -> int:
    s = read_sysctl_str(path, "")
    if not s:
        return default
    first_token = s.split()[0]
    return int(first_token) if first_token.lstrip("-").isdigit() else default


def parse_netstat_mptcpext(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("MPTcpExt:") and lines[i + 1].startswith("MPTcpExt:"):
                keys = lines[i].split()[1:]
                vals = lines[i + 1].split()[1:]
                for k, v in zip(keys, vals):
                    try:
                        metrics[k] = int(v)
                    except ValueError:
                        continue
    except (OSError, IndexError):
        pass
    return metrics


def evaluate_mptcp_subflow(
    conf_dir: str = PROC_MPTCP_DIR,
    netstat_file: str = PROC_NETSTAT,
    min_stale_loss_cnt: int = 1,
    max_stale_loss_cnt: int = 16,
    max_syn_fallback: int = 10,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    enabled = read_sysctl_int(os.path.join(conf_dir, "enabled"), default=1)
    path_manager = read_sysctl_str(os.path.join(conf_dir, "path_manager"), default="kernel")
    avail_pm_str = read_sysctl_str(os.path.join(conf_dir, "available_path_managers"), default="kernel userspace")
    scheduler = read_sysctl_str(os.path.join(conf_dir, "scheduler"), default="default")
    avail_sched_str = read_sysctl_str(os.path.join(conf_dir, "available_schedulers"), default="default")
    stale_loss_cnt = read_sysctl_int(os.path.join(conf_dir, "stale_loss_cnt"), default=4)
    syn_fallback = read_sysctl_int(os.path.join(conf_dir, "syn_retrans_before_tcp_fallback"), default=2)

    avail_pms = avail_pm_str.split() if avail_pm_str else []
    avail_scheds = avail_sched_str.split() if avail_sched_str else []

    if enabled == 0:
        issues.append("MPTCP is disabled at system level (net.mptcp.enabled=0); multipath transport inactive")
        recommendations.append("Set sysctl net.mptcp.enabled=1 to enable multipath TCP")
        status = "WARNING"

    if path_manager and avail_pms and path_manager not in avail_pms:
        issues.append(
            f"Configured path manager '{path_manager}' is not registered in available path managers: {avail_pms}"
        )
        recommendations.append(f"Set sysctl net.mptcp.path_manager to one of: {avail_pms}")
        status = "CRITICAL"

    if scheduler and avail_scheds and scheduler not in avail_scheds:
        issues.append(
            f"Configured subflow scheduler '{scheduler}' is not registered in available schedulers: {avail_scheds}"
        )
        recommendations.append(f"Set sysctl net.mptcp.scheduler to one of: {avail_scheds}")
        status = "CRITICAL"

    if stale_loss_cnt != -1 and (stale_loss_cnt < min_stale_loss_cnt or stale_loss_cnt > max_stale_loss_cnt):
        issues.append(
            f"Suboptimal net.mptcp.stale_loss_cnt ({stale_loss_cnt} outside nominal [{min_stale_loss_cnt}, {max_stale_loss_cnt}])"
        )
        recommendations.append("Set sysctl net.mptcp.stale_loss_cnt=4")
        if status != "CRITICAL":
            status = "WARNING"

    if syn_fallback != -1 and (syn_fallback < 1 or syn_fallback > max_syn_fallback):
        issues.append(
            f"Suboptimal net.mptcp.syn_retrans_before_tcp_fallback ({syn_fallback} outside nominal [1, {max_syn_fallback}])"
        )
        recommendations.append("Set sysctl net.mptcp.syn_retrans_before_tcp_fallback=2")
        if status != "CRITICAL":
            status = "WARNING"

    netstat = parse_netstat_mptcpext(netstat_file)
    fallback_failed = netstat.get("FallbackFailed", 0)
    dss_corruption_reset = netstat.get("DSSCorruptionReset", 0)
    subflow_stale = netstat.get("SubflowStale", 0)
    subflow_recover = netstat.get("SubflowRecover", 0)
    curr_estab = netstat.get("MPCurrEstab", 0)

    if fallback_failed > 0:
        issues.append(f"Elevated MPTCP fallback failures detected: FallbackFailed={fallback_failed}")
        recommendations.append("Investigate middlebox interference or DSS option stripping on path")
        status = "CRITICAL"

    if dss_corruption_reset > 0:
        issues.append(f"Elevated DSS corruption connection resets detected: DSSCorruptionReset={dss_corruption_reset}")
        recommendations.append("Audit middlebox packet mangling or corrupted TCP checksums")
        status = "CRITICAL"

    healthy = len(issues) == 0

    return {
        "pattern": 304,
        "name": "mptcp_subflow",
        "description": "Linux MPTCP Subflow Scheduler & Stale Loss Guard",
        "status": status,
        "healthy": healthy,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "mptcp_enabled": enabled,
        "path_manager": path_manager,
        "available_path_managers": avail_pms,
        "scheduler": scheduler,
        "available_schedulers": avail_scheds,
        "stale_loss_cnt": stale_loss_cnt,
        "syn_retrans_before_tcp_fallback": syn_fallback,
        "curr_estab": curr_estab,
        "subflow_stale": subflow_stale,
        "subflow_recover": subflow_recover,
        "fallback_failed": fallback_failed,
        "dss_corruption_reset": dss_corruption_reset,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Linux MPTCP Subflow Scheduler & Stale Loss Guard (Pattern 304 / Pattern 442)"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--conf-dir", default=PROC_MPTCP_DIR, help="Path to mptcp procfs directory")
    parser.add_argument("--netstat-file", default=PROC_NETSTAT, help="Path to /proc/net/netstat file")
    args = parser.parse_args()

    result = evaluate_mptcp_subflow(
        conf_dir=args.conf_dir,
        netstat_file=args.netstat_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] Pattern {result['pattern']} - {result['description']}")
        print(f"  MPTCP Enabled: {result['mptcp_enabled']}")
        print(f"  Path Manager: {result['path_manager']} (available: {result['available_path_managers']})")
        print(f"  Scheduler: {result['scheduler']} (available: {result['available_schedulers']})")
        print(f"  Stale Loss Threshold: {result['stale_loss_cnt']} retransmissions")
        print(f"  SYN Retrans Fallback Threshold: {result['syn_retrans_before_tcp_fallback']} retransmissions")
        print(f"  Active Connections: {result['curr_estab']}, Stale Subflows: {result['subflow_stale']}, Recovered: {result['subflow_recover']}")
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
