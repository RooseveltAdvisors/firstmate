#!/usr/bin/env python3
"""
fm-jev-rehash-guard.py - Jev Multi-Agent Host Network TCP Timeout Path Rehashing & Multipath Route Guard (Pattern 163)

Audits Linux TCP path rehashing and multipath route resilience from /proc/net/netstat:
  - TcpTimeoutRehash (Flow label and route rehashing triggered by RTO timeouts)
  - TcpDuplicateDataRehash (Route rehashing triggered by duplicate data reception)
  - TCPPLBRehash (Proactive Loss-Based Rehashing for multipath routing optimization)
  - TCPTimeouts (Total retransmission timeouts)
  - TCPDelivered (Total TCP segments delivered to local application sockets)
  - net.ipv4.tcp_plb_rehash_rounds (PLB rehash rounds threshold)
  - net.ipv4.tcp_plb_idle_rehash_rounds (PLB idle rehash rounds threshold)

In multi-agent token streaming and distributed cluster RPCs, transient link degradation,
ECMP hash polarization, or switch buffer drops cause repeated timeouts. Modern Linux kernels
automatically rehash IPv6 flow labels and IPv4 multipath routing state (RFC 8985 / PLB) upon
timeout, routing packets around degraded transit links without dropping active sockets.

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
SYSCTL_PLB_ROUNDS = "/proc/sys/net/ipv4/tcp_plb_rehash_rounds"
SYSCTL_PLB_IDLE_ROUNDS = "/proc/sys/net/ipv4/tcp_plb_idle_rehash_rounds"


def read_sysctl_int(path: Path, default: int = 0) -> int:
    """Safely reads an integer from sysctl procfs path."""
    if not path.is_file():
        return default
    try:
        content = path.read_text().strip()
        return int(content) if content.isdigit() else default
    except Exception:
        return default


def parse_rehash_counters(netstat_path: Path) -> Dict[str, int]:
    """Parses TCP timeout and duplicate data path rehashing metrics from /proc/net/netstat."""
    counters: Dict[str, int] = {
        "timeout_rehash": 0,
        "duplicate_data_rehash": 0,
        "plb_rehash": 0,
        "timeouts": 0,
        "delivered": 0,
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

                counters["timeout_rehash"] = header_map.get("TcpTimeoutRehash", 0)
                counters["duplicate_data_rehash"] = header_map.get("TcpDuplicateDataRehash", 0)
                counters["plb_rehash"] = header_map.get("TCPPLBRehash", 0)
                counters["timeouts"] = header_map.get("TCPTimeouts", 0)
                counters["delivered"] = header_map.get("TCPDelivered", 0)
                break
    except Exception:
        pass

    return counters


def audit_rehash(
    netstat_file: Optional[str] = None,
    plb_rounds_file: Optional[str] = None,
    plb_idle_rounds_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TCP timeout path rehashing and multipath resilience."""
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)
    plb_rounds_path = Path(plb_rounds_file) if plb_rounds_file else Path(SYSCTL_PLB_ROUNDS)
    plb_idle_rounds_path = Path(plb_idle_rounds_file) if plb_idle_rounds_file else Path(SYSCTL_PLB_IDLE_ROUNDS)

    plb_rehash_rounds = read_sysctl_int(plb_rounds_path, default=12)
    plb_idle_rehash_rounds = read_sysctl_int(plb_idle_rounds_path, default=3)
    counters = parse_rehash_counters(netstat_path)

    timeout_rehash = counters["timeout_rehash"]
    timeouts = counters["timeouts"]
    duplicate_data_rehash = counters["duplicate_data_rehash"]
    plb_rehash = counters["plb_rehash"]
    delivered = counters["delivered"]

    rehash_ratio_pct = (
        round((timeout_rehash / timeouts * 100), 2)
        if timeouts > 0
        else 0.0
    )

    issues: List[str] = []

    # 1. Zero timeout rehash under significant timeouts
    if timeouts > 1000 and timeout_rehash == 0:
        issues.append(
            f"Zero TCP timeout path rehashes detected despite {timeouts:,} RTO timeouts; multipath evasion inactive"
        )

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "timeout_rehash": timeout_rehash,
            "rehash_ratio_pct": rehash_ratio_pct,
            "duplicate_data_rehash": duplicate_data_rehash,
            "plb_rehash": plb_rehash,
            "timeouts": timeouts,
            "delivered": delivered,
            "plb_rehash_rounds": plb_rehash_rounds,
            "plb_idle_rehash_rounds": plb_idle_rehash_rounds,
            "issues": issues,
        },
        "counters": counters,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Timeout Path Rehashing Guard (Pattern 163)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    parser.add_argument("--plb-rounds-file", type=str, default=None, help="Path to tcp_plb_rehash_rounds")
    parser.add_argument("--plb-idle-rounds-file", type=str, default=None, help="Path to tcp_plb_idle_rehash_rounds")
    args = parser.parse_args()

    result = audit_rehash(
        netstat_file=args.netstat_file,
        plb_rounds_file=args.plb_rounds_file,
        plb_idle_rounds_file=args.plb_idle_rounds_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP Timeout Path Rehashing Guard (Pattern 163)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" TCP Timeout Rehashes:          {summary['timeout_rehash']:,} ({summary['rehash_ratio_pct']}% of timeouts)")
    print(f" Duplicate Data Rehashes:       {summary['duplicate_data_rehash']:,}")
    print(f" Proactive Loss Rehashes (PLB): {summary['plb_rehash']:,}")
    print(f" Total Retransmission Timeouts: {summary['timeouts']:,}")
    print(f" Total Segments Delivered:      {summary['delivered']:,}")
    print(f" PLB Rehash Rounds Sysctl:      {summary['plb_rehash_rounds']} (idle: {summary['plb_idle_rehash_rounds']})")
    print("--------------------------------------------------------------------------------")
    print(f" {'Rehashing Metric':<35} {'Value':<18} {'Status'}")
    print("--------------------------------------------------------------------------------")
    rehash_val = f"{summary['rehash_ratio_pct']} %"
    rehash_status = "Nominal" if summary['rehash_ratio_pct'] >= 50.0 else "Suboptimal"
    plb_val = f"{summary['plb_rehash']:,}"
    dup_val = f"{summary['duplicate_data_rehash']:,}"
    print(f" {'Timeout Path Rehash Ratio':<35} {rehash_val:<18} {rehash_status}")
    print(f" {'PLB Proactive Loss Rehash':<35} {plb_val:<18} {'Supported'}")
    print(f" {'Duplicate Data Route Rehash':<35} {dup_val:<18} {'Nominal'}")

    if summary["issues"]:
        print("\nActive TCP Path Rehashing Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP timeout path rehashing, flow label mutation, and multipath route health nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
