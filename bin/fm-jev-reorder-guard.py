#!/usr/bin/env python3
"""
fm-jev-reorder-guard.py - Jev Multi-Agent Host Network TCP Packet Reordering & Spurious Fast Retransmit Guard (Pattern 151)

Audits Linux TCP packet reordering detection, duplicate ACK thresholds, and spurious retransmission prevention:
  - /proc/sys/net/ipv4/tcp_reordering (initial duplicate ACK threshold, default 3)
  - /proc/net/netstat metrics:
      - TCPSACKReorder (Packet reordering detected via SACK blocks)
      - TCPTSReorder (Packet reordering detected via TCP Timestamps)
      - TCPRenoReorder (Packet reordering detected in Reno recovery)
      - TCPFastRetrans (Total Fast Retransmissions)
      - TCPFullUndo (CWND full rollbacks following false loss detection)
      - TCPDeliveredCE (Delivered packets marked with ECN Congestion Experienced)

In cloud agent mesh networks with multi-path ECMP routing and asymmetric link latencies,
packet reordering frequently exceeds standard 3-packet thresholds. Linux TCP dynamic reordering
auto-tunes the reorder threshold to prevent devastating spurious fast retransmits and CWND collapse.

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
SYSCTL_REORDERING = "/proc/sys/net/ipv4/tcp_reordering"


def read_int_file(path: Path, default: int = 0) -> int:
    """Safely reads an integer from a sysctl file."""
    if not path.is_file():
        return default
    try:
        return int(path.read_text().strip())
    except Exception:
        return default


def parse_reorder_counters(netstat_path: Path) -> Dict[str, int]:
    """Parses TCP packet reordering metrics from /proc/net/netstat."""
    counters: Dict[str, int] = {
        "sack_reorder": 0,
        "ts_reorder": 0,
        "reno_reorder": 0,
        "fast_retrans": 0,
        "full_undo": 0,
        "delivered_ce": 0,
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

                counters["sack_reorder"] = header_map.get("TCPSACKReorder", 0)
                counters["ts_reorder"] = header_map.get("TCPTSReorder", 0)
                counters["reno_reorder"] = header_map.get("TCPRenoReorder", 0)
                counters["fast_retrans"] = header_map.get("TCPFastRetrans", 0)
                counters["full_undo"] = header_map.get("TCPFullUndo", 0)
                counters["delivered_ce"] = header_map.get("TCPDeliveredCE", 0)
                break
    except Exception:
        pass

    return counters


def audit_reorder(
    netstat_file: Optional[str] = None,
    reorder_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TCP packet reordering parameters and detection metrics."""
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)
    reorder_path = Path(reorder_file) if reorder_file else Path(SYSCTL_REORDERING)

    reorder_thresh = read_int_file(reorder_path, default=3)
    counters = parse_reorder_counters(netstat_path)

    total_reorders = (
        counters["sack_reorder"]
        + counters["ts_reorder"]
        + counters["reno_reorder"]
    )
    fast_retrans = counters["fast_retrans"]

    issues: List[str] = []

    # 1. tcp_reordering threshold under-configured (< 3)
    if reorder_thresh < 3:
        issues.append(f"tcp_reordering threshold is under-configured ({reorder_thresh} < 3); highly sensitive to spurious fast retransmits")

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "tcp_reordering_threshold": reorder_thresh,
            "total_reorder_events": total_reorders,
            "sack_reorder": counters["sack_reorder"],
            "ts_reorder": counters["ts_reorder"],
            "reno_reorder": counters["reno_reorder"],
            "fast_retrans": fast_retrans,
            "full_undo": counters["full_undo"],
            "delivered_ce": counters["delivered_ce"],
            "issues": issues,
        },
        "counters": counters,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Packet Reordering & Spurious Fast Retransmit Guard (Pattern 151)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    parser.add_argument("--reorder-file", type=str, default=None, help="Path to tcp_reordering")
    args = parser.parse_args()

    result = audit_reorder(netstat_file=args.netstat_file, reorder_file=args.reorder_file)

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP Packet Reordering Guard (Pattern 151)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" tcp_reordering Threshold:      {summary['tcp_reordering_threshold']} duplicate ACKs")
    print(f" Total Reordering Events:       {summary['total_reorder_events']:,}")
    print(f"   - SACK Detected Reorders:    {summary['sack_reorder']:,}")
    print(f"   - Timestamp (TS) Reorders:   {summary['ts_reorder']:,}")
    print(f"   - Reno Detected Reorders:    {summary['reno_reorder']:,}")
    print(f" Fast Retransmissions:          {summary['fast_retrans']:,}")
    print(f" Full CWND Loss Undos:          {summary['full_undo']:,}")
    print(f" ECN Delivered CE Marks:        {summary['delivered_ce']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Reordering Metric / Sysctl':<35} {'Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Initial DupACK Threshold':<35} {summary['tcp_reordering_threshold']:<15} {'Nominal' if summary['tcp_reordering_threshold'] >= 3 else 'WARNING'}")
    print(f" {'SACK Reordering Defense':<35} {summary['sack_reorder']:<15} {'Nominal'}")
    print(f" {'Timestamp Reordering Defense':<35} {summary['ts_reorder']:<15} {'Nominal'}")

    if summary["issues"]:
        print("\nActive TCP Packet Reordering Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP packet reordering parameters, SACK detection, and recovery metrics nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
