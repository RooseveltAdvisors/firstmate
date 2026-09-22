#!/usr/bin/env python3
"""
fm-jev-fack-guard.py - Jev Multi-Agent Host Network TCP FACK & Loss Recovery Reneging Guard (Pattern 132)

Audits Linux TCP Forward Acknowledgment policy (/proc/sys/net/ipv4/tcp_fack),
reordering thresholds (/proc/sys/net/ipv4/tcp_reordering, /proc/sys/net/ipv4/tcp_max_reordering),
Selective ACK enablement (/proc/sys/net/ipv4/tcp_sack, /proc/sys/net/ipv4/tcp_dsack),
and SACK recovery failure / reneging counters from /proc/net/netstat.

In multi-agent architectures running across hybrid clouds and heterogeneous network links,
misconfigured SACK loss recovery or peer reneging causes spurious retransmissions and RTO stalls.
Detects receiver reneging episodes (where a receiver claims data via SACK but drops it from buffer)
and calculates SACK recovery failure ratios.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysctl or procfs entries are inaccessible.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

SYSCTL_FACK = "/proc/sys/net/ipv4/tcp_fack"
SYSCTL_REORDERING = "/proc/sys/net/ipv4/tcp_reordering"
SYSCTL_MAX_REORDERING = "/proc/sys/net/ipv4/tcp_max_reordering"
SYSCTL_SACK = "/proc/sys/net/ipv4/tcp_sack"
SYSCTL_DSACK = "/proc/sys/net/ipv4/tcp_dsack"

PROC_NETSTAT = "/proc/net/netstat"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def parse_proc_pairs(path: Path, section_name: str) -> Dict[str, int]:
    """Parses paired header/metric lines from /proc/net/netstat."""
    if not path.is_file():
        return {}

    metrics: Dict[str, int] = {}
    try:
        lines = path.read_text().splitlines()
        for i in range(0, len(lines) - 1):
            line = lines[i]
            if line.startswith(f"{section_name}:"):
                keys = line.split()[1:]
                next_line = lines[i + 1]
                if next_line.startswith(f"{section_name}:"):
                    vals = next_line.split()[1:]
                    for k, v in zip(keys, vals):
                        try:
                            metrics[k] = int(v)
                        except ValueError:
                            continue
                    break
    except Exception:
        return {}

    return metrics


def audit_fack(
    fack_file: Optional[str] = None,
    reordering_file: Optional[str] = None,
    max_reordering_file: Optional[str] = None,
    sack_file: Optional[str] = None,
    dsack_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host TCP FACK, SACK reneging, and loss recovery metrics."""
    fack_p = Path(fack_file or SYSCTL_FACK)
    reord_p = Path(reordering_file or SYSCTL_REORDERING)
    max_reord_p = Path(max_reordering_file or SYSCTL_MAX_REORDERING)
    sack_p = Path(sack_file or SYSCTL_SACK)
    dsack_p = Path(dsack_file or SYSCTL_DSACK)

    netstat_p = Path(netstat_file or PROC_NETSTAT)

    fack = read_int_file(fack_p)
    if fack is None:
        fack = 0

    reordering = read_int_file(reord_p)
    if reordering is None:
        reordering = 3

    max_reordering = read_int_file(max_reord_p)
    if max_reordering is None:
        max_reordering = 300

    sack = read_int_file(sack_p)
    if sack is None:
        sack = 1

    dsack = read_int_file(dsack_p)
    if dsack is None:
        dsack = 1

    netstat_tcp = parse_proc_pairs(netstat_p, "TcpExt")

    sack_recovery = netstat_tcp.get("TCPSackRecovery", 0)
    sack_recovery_fail = netstat_tcp.get("TCPSackRecoveryFail", 0)
    sack_reneging = netstat_tcp.get("TCPSACKReneging", 0)
    dsack_recv = netstat_tcp.get("TCPDSACKRecv", 0)
    dsack_undo = netstat_tcp.get("TCPDSACKUndo", 0)
    rcv_collapsed = netstat_tcp.get("TCPRcvCollapsed", 0)

    issues: List[str] = []
    healthy = True

    if sack == 0:
        healthy = False
        issues.append("Selective ACK is disabled (tcp_sack = 0). Kernel cannot use SACK blocks for fast recovery.")

    if dsack == 0:
        issues.append("Duplicate SACK is disabled (tcp_dsack = 0). Spurious retransmission detection degraded.")

    fail_pct = (sack_recovery_fail / sack_recovery * 100.0) if sack_recovery > 0 else 0.0
    if fail_pct > 25.0:
        healthy = False
        issues.append(f"High SACK recovery failure rate ({fail_pct:.1f}% of episodes degraded to RTO timeout).")

    if sack_reneging > 100:
        healthy = False
        issues.append(f"Elevated SACK reneging ({sack_reneging:,} episodes). Remote receiver discarding acknowledged data under memory pressure.")

    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "tcp_fack": fack,
            "tcp_sack": sack,
            "tcp_dsack": dsack,
            "tcp_reordering": reordering,
            "tcp_max_reordering": max_reordering,
            "sack_recovery": sack_recovery,
            "sack_recovery_fail": sack_recovery_fail,
            "sack_fail_pct": round(fail_pct, 2),
            "sack_reneging": sack_reneging,
            "dsack_recv": dsack_recv,
            "dsack_undo": dsack_undo,
            "rcv_collapsed": rcv_collapsed,
            "issues": issues,
        },
        "counters": {
            "sack_recovery": sack_recovery,
            "sack_recovery_fail": sack_recovery_fail,
            "sack_reneging": sack_reneging,
            "dsack_recv": dsack_recv,
            "dsack_undo": dsack_undo,
            "rcv_collapsed": rcv_collapsed,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP FACK & Loss Recovery Reneging Guard (Pattern 132)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--fack-file", type=str, default=None, help="Path to tcp_fack")
    parser.add_argument("--reordering-file", type=str, default=None, help="Path to tcp_reordering")
    parser.add_argument("--max-reordering-file", type=str, default=None, help="Path to tcp_max_reordering")
    parser.add_argument("--sack-file", type=str, default=None, help="Path to tcp_sack")
    parser.add_argument("--dsack-file", type=str, default=None, help="Path to tcp_dsack")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_fack(
        fack_file=args.fack_file,
        reordering_file=args.reordering_file,
        max_reordering_file=args.max_reordering_file,
        sack_file=args.sack_file,
        dsack_file=args.dsack_file,
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
    print(" Jev Multi-Agent Host Network TCP FACK & Reneging Guard (Pattern 132)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" SACK / DSACK Status:           {'Enabled (1)' if summary['tcp_sack'] == 1 else 'Disabled (0)'} / {'Enabled (1)' if summary['tcp_dsack'] == 1 else 'Disabled (0)'}")
    print(f" FACK Status (tcp_fack):        {summary['tcp_fack']} ({'Superseded by RACK' if summary['tcp_fack'] == 0 else 'Active'})")
    print(f" Packet Reordering Metric:      {summary['tcp_reordering']} (Max: {summary['tcp_max_reordering']})")
    print(f" SACK Recovery Episodes:        {counters['sack_recovery']:,}")
    print(f" SACK Recovery Failures (RTO):  {counters['sack_recovery_fail']:,} ({summary['sack_fail_pct']}%)")
    print(f" SACK Reneging Events:          {counters['sack_reneging']}")
    print(f" DSACK Undos (CWND Restored):   {counters['dsack_undo']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'FACK / SACK Recovery Metric':<35} {'Count / Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'tcp_sack':<35} {summary['tcp_sack']:<15} {'Nominal' if summary['tcp_sack'] == 1 else 'WARNING'}")
    print(f" {'SACK Recovery Failure Ratio':<35} {summary['sack_fail_pct']:<14}% {'Nominal' if summary['sack_fail_pct'] <= 25.0 else 'WARNING'}")
    print(f" {'SACK Reneging Events':<35} {counters['sack_reneging']:<15} {'Nominal' if counters['sack_reneging'] <= 100 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive FACK / SACK Reneging Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP FACK parameters, SACK recovery health, and reneging counters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
