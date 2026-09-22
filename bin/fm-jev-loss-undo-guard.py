#!/usr/bin/env python3
"""
fm-jev-loss-undo-guard.py - Jev Multi-Agent Host Network TCP Loss Recovery Undos & Spurious Retransmit Guard (Pattern 144)

Audits Linux TCP congestion window (CWND) loss recovery undos and spurious retransmissions from /proc/net/netstat:
  - TCPFullUndo (Full congestion window rollback via timestamps or DSACK)
  - TCPPartialUndo (Partial rollback via Hoe heuristic)
  - TCPDSACKUndo (CWND rollback triggered by Duplicate SACK confirmation)
  - TCPLossUndo (CWND rollback during loss recovery)
  - TCPLostRetransmit (Lost retransmitted packets)
  - TCPFastRetrans (Fast retransmissions)
  - TCPSlowStartRetrans (Slow start retransmissions)
  - TCPTimeouts (RTO timeouts)

In multi-cloud agent mesh architectures with variable latency links, excessive CWND undos signal
premature retransmission triggered by packet reordering or transient ACK jitter, wasting egress bandwidth
and causing micro-burst buffer spikes.

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


def parse_netstat_undo_counters(netstat_path: Path) -> Dict[str, int]:
    """Parses TCP undo and retransmission metrics from /proc/net/netstat."""
    counters: Dict[str, int] = {
        "full_undo": 0,
        "partial_undo": 0,
        "dsack_undo": 0,
        "loss_undo": 0,
        "lost_retransmit": 0,
        "fast_retrans": 0,
        "slow_start_retrans": 0,
        "timeouts": 0,
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

                counters["full_undo"] = header_map.get("TCPFullUndo", 0)
                counters["partial_undo"] = header_map.get("TCPPartialUndo", 0)
                counters["dsack_undo"] = header_map.get("TCPDSACKUndo", 0)
                counters["loss_undo"] = header_map.get("TCPLossUndo", 0)
                counters["lost_retransmit"] = header_map.get("TCPLostRetransmit", 0)
                counters["fast_retrans"] = header_map.get("TCPFastRetrans", 0)
                counters["slow_start_retrans"] = header_map.get("TCPSlowStartRetrans", 0)
                counters["timeouts"] = header_map.get("TCPTimeouts", 0)
                break
    except Exception:
        pass

    return counters


def audit_loss_undo(netstat_file: Optional[str] = None) -> Dict[str, Any]:
    """Performs an audit of TCP loss recovery undos and spurious retransmissions."""
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)
    counters = parse_netstat_undo_counters(netstat_path)

    total_undos = (
        counters["full_undo"]
        + counters["partial_undo"]
        + counters["dsack_undo"]
        + counters["loss_undo"]
    )
    fast_retrans = counters["fast_retrans"]
    undo_ratio_pct = round((total_undos / fast_retrans * 100), 2) if fast_retrans > 0 else 0.0

    lost_retrans = counters["lost_retransmit"]
    lost_retrans_pct = round((lost_retrans / fast_retrans * 100), 2) if fast_retrans > 0 else 0.0

    issues: List[str] = []

    # High undo ratio (> 50%) indicates highly premature retransmission
    if fast_retrans >= 1000 and undo_ratio_pct > 50.0:
        issues.append(
            f"High CWND undo ratio ({undo_ratio_pct}%): majority of fast retransmissions were unnecessary"
        )

    # High lost retransmission ratio (> 100%) indicates severe congestion or persistent link loss
    if fast_retrans >= 1000 and lost_retrans_pct > 150.0:
        issues.append(
            f"Severe retransmission loss detected ({lost_retrans:,} lost retransmissions, {lost_retrans_pct}% of fast rtx)"
        )

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "total_undos": total_undos,
            "fast_retrans": fast_retrans,
            "undo_ratio_pct": undo_ratio_pct,
            "lost_retrans": lost_retrans,
            "lost_retrans_pct": lost_retrans_pct,
            "issues": issues,
        },
        "counters": counters,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Loss Recovery Undos & Spurious Retransmit Guard (Pattern 144)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_loss_undo(netstat_file=args.netstat_file)

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP Loss Undo & Spurious Retransmit Guard (Pattern 144)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Total CWND Undos:              {summary['total_undos']:,} ({summary['undo_ratio_pct']}% of fast rtx)")
    print(f"   - Full Undos (TS/DSACK):     {counters['full_undo']:,}")
    print(f"   - DSACK Undos:               {counters['dsack_undo']:,}")
    print(f"   - Loss Undos:                {counters['loss_undo']:,}")
    print(f"   - Partial Undos (Hoe):       {counters['partial_undo']:,}")
    print(f" Fast Retransmissions:          {counters['fast_retrans']:,}")
    print(f" Lost Retransmissions:          {counters['lost_retransmit']:,} ({summary['lost_retrans_pct']}%)")
    print(f" Slow Start Retransmissions:    {counters['slow_start_retrans']:,}")
    print(f" RTO Retransmission Timeouts:   {counters['timeouts']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Loss Recovery Metric':<35} {'Count / Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'CWND Undo Ratio':<35} {summary['undo_ratio_pct']:<14}% {'Nominal' if summary['undo_ratio_pct'] <= 50.0 else 'WARNING'}")
    print(f" {'DSACK Undos':<35} {counters['dsack_undo']:<15} {'Nominal'}")
    print(f" {'Lost Retransmissions':<35} {counters['lost_retransmit']:<15} {'Nominal' if summary['lost_retrans_pct'] <= 150.0 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive TCP Loss Recovery / Spurious Retransmission Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP loss recovery undos, DSACK rollbacks, and retransmission metrics nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
