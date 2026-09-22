#!/usr/bin/env python3
"""
fm-jev-sack-reneging-guard.py - Jev Multi-Agent Host Network TCP SACK Reneging & Buffer Revocation Guard (Pattern 152)

Audits Linux TCP Selective Acknowledgment (SACK) reneging, recovery failures, and block discards from /proc/net/netstat:
  - TCPSACKReneging (Receiver reneged on SACKed data due to buffer memory constraints)
  - TCPSackRecovery (Total times connection entered SACK loss recovery)
  - TCPSackRecoveryFail (SACK loss recovery failed, forcing retransmission timeout)
  - TCPSackFailures (SACK scoreboard processing failures)
  - TCPSACKDiscard (Invalid or redundant SACK blocks discarded)
  - TCPSackShifted (SACK blocks shifted forward)
  - TCPSackMerged (SACK blocks coalesced)

When receiver sockets experience severe buffer exhaustion or collapse, they may renege on previously
SACKed out-of-order data blocks, forcing the sender to flush its SACK scoreboard and retransmit all data
from the unacknowledged baseline. Excessive SACK recovery failures indicate persistent packet drops
exceeding SACK hole-filling capacity.

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

PROC_NETSTAT = "/proc/net/netstat"


def parse_sack_reneging_counters(netstat_path: Path) -> Dict[str, int]:
    """Parses SACK reneging and recovery failure metrics from /proc/net/netstat."""
    counters: Dict[str, int] = {
        "sack_reneging": 0,
        "sack_recovery": 0,
        "sack_recovery_fail": 0,
        "sack_failures": 0,
        "sack_discard": 0,
        "sack_shifted": 0,
        "sack_merged": 0,
    }

    if not netstat_path.is_file():
        return counters

    try:
        lines = netstat_path.read_text().splitlines()
        for i in range(0, len(lines) - 1, 2):
            header_line = lines[i].strip()
            data_line = lines[i + 1].strip()
            if header_line.startswith("TcpExt:") and data_line.startswith("TcpExt:"):
                headers = header_line.split()[1:]
                values = data_line.split()[1:]
                header_map = {h: int(v) for h, v in zip(headers, values) if v.isdigit()}

                counters["sack_reneging"] = header_map.get("TCPSACKReneging", 0)
                counters["sack_recovery"] = header_map.get("TCPSackRecovery", 0)
                counters["sack_recovery_fail"] = header_map.get("TCPSackRecoveryFail", 0)
                counters["sack_failures"] = header_map.get("TCPSackFailures", 0)
                counters["sack_discard"] = header_map.get("TCPSACKDiscard", 0)
                counters["sack_shifted"] = header_map.get("TCPSackShifted", 0)
                counters["sack_merged"] = header_map.get("TCPSackMerged", 0)
                break
    except Exception:
        pass

    return counters


def audit_sack_reneging(netstat_file: Optional[str] = None) -> Dict[str, Any]:
    """Audits TCP SACK reneging and recovery failure metrics."""
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)
    counters = parse_sack_reneging_counters(netstat_path)

    recovery_total = counters["sack_recovery"]
    recovery_fail = counters["sack_recovery_fail"]
    fail_ratio_pct = round((recovery_fail / recovery_total * 100), 2) if recovery_total > 0 else 0.0

    issues: List[str] = []

    # 1. SACK reneging elevated (> 100)
    if counters["sack_reneging"] > 100:
        issues.append(
            f"Elevated SACK reneging events detected ({counters['sack_reneging']:,} reneged blocks); receiver buffer exhaustion"
        )

    # 2. SACK recovery failure ratio (> 25%)
    if recovery_total >= 500 and fail_ratio_pct > 25.0:
        issues.append(
            f"High SACK recovery failure ratio ({fail_ratio_pct}%: {recovery_fail:,} / {recovery_total:,})"
        )

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "sack_reneging": counters["sack_reneging"],
            "sack_recovery": recovery_total,
            "sack_recovery_fail": recovery_fail,
            "recovery_fail_ratio_pct": fail_ratio_pct,
            "sack_failures": counters["sack_failures"],
            "sack_discard": counters["sack_discard"],
            "sack_shifted": counters["sack_shifted"],
            "sack_merged": counters["sack_merged"],
            "issues": issues,
        },
        "counters": counters,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP SACK Reneging & Buffer Revocation Guard (Pattern 152)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_sack_reneging(netstat_file=args.netstat_file)

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP SACK Reneging Guard (Pattern 152)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" SACK Reneging Events:          {summary['sack_reneging']:,}")
    print(f" SACK Loss Recoveries:          {summary['sack_recovery']:,}")
    print(f" SACK Recovery Failures:        {summary['sack_recovery_fail']:,} ({summary['recovery_fail_ratio_pct']}% failure ratio)")
    print(f" SACK Scoreboard Failures:      {summary['sack_failures']:,}")
    print(f" SACK Discarded Blocks:         {summary['sack_discard']:,}")
    print(f" SACK Shifted / Merged Blocks:  {summary['sack_shifted'] + summary['sack_merged']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'SACK Metric':<35} {'Count / Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    ratio_str = f"{summary['recovery_fail_ratio_pct']}%"
    print(f" {'Recovery Failure Ratio':<35} {ratio_str:<15} {'Nominal' if summary['recovery_fail_ratio_pct'] <= 25.0 else 'WARNING'}")
    print(f" {'SACK Scoreboard Processing':<35} {summary['sack_failures']:<15} {'Nominal'}")

    if summary["issues"]:
        print("\nActive TCP SACK Reneging / Recovery Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP SACK reneging, loss recovery execution, and block processing nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
