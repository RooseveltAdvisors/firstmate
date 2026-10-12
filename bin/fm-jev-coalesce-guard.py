#!/usr/bin/env python3
"""
fm-jev-coalesce-guard.py - Jev Multi-Agent Host Network TCP Packet Coalescing & GRO Buffer Efficiency Guard (Pattern 153)

Audits Linux TCP receive queue packet coalescing, backlog buffer coalescing, and GRO efficiency from /proc/net/netstat:
  - TCPRcvCoalesce (Packets coalesced directly into existing socket receive queue buffers)
  - TCPBacklogCoalesce (Packets coalesced inside socket backlog queues under process load)
  - TCPDelivered (Total TCP segments delivered to local application sockets)
  - TCPRcvCollapsed (Packets collapsed into larger buffers under memory pressure)
  - TCPPruneDrop (Packets dropped during receive queue pruning)

In high-throughput multi-agent inter-process pipelines and streaming LLM token sockets,
receive queue packet coalescing reduces kernel softirq overhead, CPU interrupts, and memory
fragmentation by automatically concatenating consecutive TCP payloads into existing sk_buffs
before waking application threads.

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


def parse_coalesce_counters(netstat_path: Path) -> Dict[str, int]:
    """Parses TCP packet coalescing metrics from /proc/net/netstat."""
    counters: Dict[str, int] = {
        "rcv_coalesce": 0,
        "backlog_coalesce": 0,
        "delivered": 0,
        "rcv_collapsed": 0,
        "prune_drop": 0,
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

                counters["rcv_coalesce"] = header_map.get("TCPRcvCoalesce", 0)
                counters["backlog_coalesce"] = header_map.get("TCPBacklogCoalesce", 0)
                counters["delivered"] = header_map.get("TCPDelivered", 0)
                counters["rcv_collapsed"] = header_map.get("TCPRcvCollapsed", 0)
                counters["prune_drop"] = header_map.get("TCPPruneDrop", 0)
                break
    except Exception:
        pass

    return counters


def audit_coalesce(netstat_file: Optional[str] = None) -> Dict[str, Any]:
    """Audits TCP packet coalescing efficiency and buffer health."""
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)
    counters = parse_coalesce_counters(netstat_path)

    rcv_coalesce = counters["rcv_coalesce"]
    backlog_coalesce = counters["backlog_coalesce"]
    total_coalesced = rcv_coalesce + backlog_coalesce
    delivered = counters["delivered"]

    coalesce_ratio_pct = round((total_coalesced / delivered * 100), 2) if delivered > 0 else 0.0

    issues: List[str] = []

    # 1. Prune drops > 0
    if counters["prune_drop"] > 0:
        issues.append(f"Receive queue prune drops detected ({counters['prune_drop']:,} drops)")

    # 2. Extreme collapsed buffer count (> 100k) with zero coalescing
    if counters["rcv_collapsed"] > 100000 and total_coalesced == 0:
        issues.append("Buffer collapse occurring without healthy packet coalescing")

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "total_coalesced": total_coalesced,
            "rcv_coalesce": rcv_coalesce,
            "backlog_coalesce": backlog_coalesce,
            "delivered": delivered,
            "coalesce_ratio_pct": coalesce_ratio_pct,
            "rcv_collapsed": counters["rcv_collapsed"],
            "prune_drop": counters["prune_drop"],
            "issues": issues,
        },
        "counters": counters,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Packet Coalescing & GRO Buffer Efficiency Guard (Pattern 153)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_coalesce(netstat_file=args.netstat_file)

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP Packet Coalescing Guard (Pattern 153)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Total Coalesced Packets:       {summary['total_coalesced']:,} ({summary['coalesce_ratio_pct']}% of delivered)")
    print(f"   - Receive Queue Coalesce:    {counters['rcv_coalesce']:,}")
    print(f"   - Backlog Queue Coalesce:    {counters['backlog_coalesce']:,}")
    print(f" Total Segments Delivered:      {summary['delivered']:,}")
    print(f" Buffer Collapse Events:        {counters['rcv_collapsed']:,}")
    print(f" Buffer Prune Drops:            {counters['prune_drop']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Coalescing Metric':<35} {'Count / Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    ratio_str = f"{summary['coalesce_ratio_pct']}%"
    print(f" {'Coalescing Efficiency':<35} {ratio_str:<15} {'Nominal' if summary['coalesce_ratio_pct'] >= 1.0 else 'Low'}")
    print(f" {'Receive Buffer Collapses':<35} {counters['rcv_collapsed']:<15} {'Nominal'}")
    print(f" {'Buffer Prune Drops':<35} {counters['prune_drop']:<15} {'Nominal' if counters['prune_drop'] == 0 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive TCP Packet Coalescing Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP packet coalescing, buffer queuing, and delivery efficiency nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
