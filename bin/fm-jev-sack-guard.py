#!/usr/bin/env python3
"""
fm-jev-sack-guard.py - Jev Multi-Agent Host Network TCP Window Scale & SACK Reneging Guard (Pattern 102)

Audits Linux host TCP window scaling, SACK / D-SACK sysctls, and loss recovery counters from
/proc/sys/net/ipv4/tcp_sack, tcp_window_scaling, tcp_dsack, tcp_rmem, tcp_wmem, and /proc/net/netstat (TcpExt).

Detects disabled SACK/window scaling, SACK reneging under receiver buffer pressure, and recovery abort
failures during high-throughput multi-agent artifact sync, model asset distribution, and database replication.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysfs/procfs files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SYSCTL_TCP_SACK = "/proc/sys/net/ipv4/tcp_sack"
SYSCTL_WINDOW_SCALING = "/proc/sys/net/ipv4/tcp_window_scaling"
SYSCTL_TCP_DSACK = "/proc/sys/net/ipv4/tcp_dsack"
SYSCTL_TCP_RMEM = "/proc/sys/net/ipv4/tcp_rmem"
SYSCTL_TCP_WMEM = "/proc/sys/net/ipv4/tcp_wmem"
PROC_NETSTAT = "/proc/net/netstat"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def read_triplet_file(path: Path) -> Tuple[Optional[int], Optional[int], Optional[int]]:
    """Reads 3 buffer thresholds (min, default, max) from a sysctl file."""
    if not path.is_file():
        return None, None, None
    try:
        parts = path.read_text().strip().split()
        if len(parts) >= 3:
            return int(parts[0]), int(parts[1]), int(parts[2])
    except Exception:
        pass
    return None, None, None


def parse_tcpext_netstat(path: Path) -> Dict[str, int]:
    """Parses TcpExt key-value metrics from /proc/net/netstat."""
    if not path.is_file():
        return {}

    metrics: Dict[str, int] = {}
    try:
        lines = path.read_text().splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("TcpExt:") and lines[i + 1].startswith("TcpExt:"):
                keys = lines[i].split()[1:]
                vals = lines[i + 1].split()[1:]
                for k, v in zip(keys, vals):
                    try:
                        metrics[k] = int(v)
                    except ValueError:
                        continue
                break
    except Exception:
        pass

    return metrics


def audit_sack_scaling(
    sack_file: Optional[str] = None,
    scaling_file: Optional[str] = None,
    dsack_file: Optional[str] = None,
    rmem_file: Optional[str] = None,
    wmem_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TCP SACK, window scaling, and loss recovery counters."""
    sack_path = Path(sack_file) if sack_file else Path(SYSCTL_TCP_SACK)
    scaling_path = Path(scaling_file) if scaling_file else Path(SYSCTL_WINDOW_SCALING)
    dsack_path = Path(dsack_file) if dsack_file else Path(SYSCTL_TCP_DSACK)
    rmem_path = Path(rmem_file) if rmem_file else Path(SYSCTL_TCP_RMEM)
    wmem_path = Path(wmem_file) if wmem_file else Path(SYSCTL_TCP_WMEM)
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)

    tcp_sack = read_int_file(sack_path)
    tcp_scaling = read_int_file(scaling_path)
    tcp_dsack = read_int_file(dsack_path)

    rmem_min, rmem_def, rmem_max = read_triplet_file(rmem_path)
    wmem_min, wmem_def, wmem_max = read_triplet_file(wmem_path)

    tcpext = parse_tcpext_netstat(netstat_path)

    sack_recovery = tcpext.get("TCPSackRecovery", 0)
    sack_reneging = tcpext.get("TCPSACKReneging", 0)
    sack_reorder = tcpext.get("TCPSACKReorder", 0)
    sack_discard = tcpext.get("TCPSACKDiscard", 0)
    sack_failures = tcpext.get("TCPSackFailures", 0)
    dsack_recv = tcpext.get("TCPDSACKRecv", 0)
    dsack_old_sent = tcpext.get("TCPDSACKOldSent", 0)

    fail_rate_pct = (sack_failures / sack_recovery * 100.0) if sack_recovery > 0 else 0.0

    issues: List[str] = []

    if tcp_sack is not None and tcp_sack == 0:
        issues.append("TCP SACK disabled (tcp_sack=0): packet loss causes full window retransmissions")

    if tcp_scaling is not None and tcp_scaling == 0:
        issues.append("TCP Window Scaling disabled (tcp_window_scaling=0): throughput capped at 64KB window limit")

    if sack_reneging > 10:
        issues.append(f"Elevated TCP SACK reneging ({sack_reneging}): receiver memory pressure discarding queued packets")

    if sack_recovery > 100 and fail_rate_pct > 10.0:
        issues.append(f"High SACK recovery failure rate ({fail_rate_pct:.1f}%): loss recovery aborting to slow-start timeouts")

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_sack_enabled": tcp_sack == 1 if tcp_sack is not None else True,
            "tcp_window_scaling_enabled": tcp_scaling == 1 if tcp_scaling is not None else True,
            "tcp_dsack_enabled": tcp_dsack == 1 if tcp_dsack is not None else True,
            "sack_recovery_events": sack_recovery,
            "sack_failures": sack_failures,
            "sack_failure_rate_pct": round(fail_rate_pct, 2),
            "sack_reneging_events": sack_reneging,
            "rmem_max_bytes": rmem_max,
            "wmem_max_bytes": wmem_max,
            "issues": issues,
        },
        "counters": {
            "sack_recovery": sack_recovery,
            "sack_reneging": sack_reneging,
            "sack_reorder": sack_reorder,
            "sack_discard": sack_discard,
            "sack_failures": sack_failures,
            "dsack_recv": dsack_recv,
            "dsack_old_sent": dsack_old_sent,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Window Scale & SACK Reneging Guard (Pattern 102)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--sack-file", type=str, default=None, help="Path to tcp_sack")
    parser.add_argument("--scaling-file", type=str, default=None, help="Path to tcp_window_scaling")
    parser.add_argument("--dsack-file", type=str, default=None, help="Path to tcp_dsack")
    parser.add_argument("--rmem-file", type=str, default=None, help="Path to tcp_rmem")
    parser.add_argument("--wmem-file", type=str, default=None, help="Path to tcp_wmem")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_sack_scaling(
        sack_file=args.sack_file,
        scaling_file=args.scaling_file,
        dsack_file=args.dsack_file,
        rmem_file=args.rmem_file,
        wmem_file=args.wmem_file,
        netstat_file=args.netstat_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP Window Scale & SACK Guard (Pattern 102)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" TCP SACK:                      {'Enabled' if summary['tcp_sack_enabled'] else 'DISABLED'}")
    print(f" TCP Window Scaling:            {'Enabled' if summary['tcp_window_scaling_enabled'] else 'DISABLED'}")
    print(f" TCP D-SACK:                    {'Enabled' if summary['tcp_dsack_enabled'] else 'DISABLED'}")
    print(f" Max RMEM / WMEM:               {summary['rmem_max_bytes']} / {summary['wmem_max_bytes']} bytes")
    print("--------------------------------------------------------------------------------")
    print(f" {'Loss Recovery Metric':<30} {'Count':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'SACK Recovery Episodes':<30} {counters['sack_recovery']:<15} Nominal")
    print(f" {'SACK Failures':<30} {counters['sack_failures']:<15} {summary['sack_failure_rate_pct']}% fail rate")
    print(f" {'SACK Reneging Events':<30} {counters['sack_reneging']:<15} {'Nominal' if counters['sack_reneging'] <= 10 else 'WARNING'}")
    print(f" {'SACK Reorder Detections':<30} {counters['sack_reorder']:<15} Nominal")
    print(f" {'SACK Discards':<30} {counters['sack_discard']:<15} Nominal")
    print(f" {'D-SACK Blocks Received':<30} {counters['dsack_recv']:<15} Nominal")

    if summary["issues"]:
        print("\nActive TCP Window Scaling / SACK Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll TCP SACK, window scaling, and loss recovery parameters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
