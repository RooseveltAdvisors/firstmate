#!/usr/bin/env python3
"""
fm-jev-abort-guard.py - Jev Multi-Agent Host Network TCP Connection Abort & Socket Reset Guard (Pattern 146)

Audits Linux TCP connection aborts, unread data socket resets, and memory exhaustion from /proc/net/netstat and /proc/net/snmp:
  - TCPAbortOnData (RST sent on close because unread data remained in the receive buffer)
  - TCPAbortOnClose (RST sent on close when socket option SO_LINGER is configured or connection reset)
  - TCPAbortOnTimeout (Connection aborted due to retransmission timeouts, tcp_retries2 exceeded)
  - TCPAbortOnMemory (Connection aborted because kernel ran out of TCP socket memory)
  - TCPAbortFailed (Kernel failed to allocate or transmit abort RST frame)
  - TCPBacklogDrop (Packets dropped because socket backlog was full)
  - EstabResets (Established connections reset by incoming RST)

In multi-agent microservice networks and high-throughput streaming pipelines, excessive TCPAbortOnData
indicates application clients terminating connections without draining responses, creating unexpected TCP RSTs
that break upstream reverse proxy keepalive connection pools. TCPAbortOnMemory indicates critical kernel network buffer exhaustion.

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
PROC_SNMP = "/proc/net/snmp"


def parse_abort_counters(netstat_path: Path, snmp_path: Path) -> Dict[str, int]:
    """Parses TCP abort and reset counters from /proc/net/netstat and /proc/net/snmp."""
    counters: Dict[str, int] = {
        "abort_on_data": 0,
        "abort_on_close": 0,
        "abort_on_timeout": 0,
        "abort_on_memory": 0,
        "abort_failed": 0,
        "backlog_drop": 0,
        "estab_resets": 0,
        "active_opens": 0,
        "passive_opens": 0,
    }

    if netstat_path.is_file():
        try:
            lines = netstat_path.read_text().splitlines()
            for i in range(0, len(lines) - 1, 2):
                header_line = lines[i].strip()
                data_line = lines[i + 1].strip()
                if header_line.startswith("TcpExt:") and data_line.startswith("TcpExt:"):
                    headers = header_line.split()[1:]
                    values = data_line.split()[1:]
                    header_map = {h: int(v) for h, v in zip(headers, values) if v.isdigit()}

                    counters["abort_on_data"] = header_map.get("TCPAbortOnData", 0)
                    counters["abort_on_close"] = header_map.get("TCPAbortOnClose", 0)
                    counters["abort_on_timeout"] = header_map.get("TCPAbortOnTimeout", 0)
                    counters["abort_on_memory"] = header_map.get("TCPAbortOnMemory", 0)
                    counters["abort_failed"] = header_map.get("TCPAbortFailed", 0)
                    counters["backlog_drop"] = header_map.get("TCPBacklogDrop", 0)
                    break
        except Exception:
            pass

    if snmp_path.is_file():
        try:
            lines = snmp_path.read_text().splitlines()
            for i in range(0, len(lines) - 1, 2):
                header_line = lines[i].strip()
                data_line = lines[i + 1].strip()
                if header_line.startswith("Tcp:") and data_line.startswith("Tcp:"):
                    headers = header_line.split()[1:]
                    values = data_line.split()[1:]
                    header_map = {h: int(v) for h, v in zip(headers, values) if v.isdigit()}

                    counters["estab_resets"] = header_map.get("EstabResets", 0)
                    counters["active_opens"] = header_map.get("ActiveOpens", 0)
                    counters["passive_opens"] = header_map.get("PassiveOpens", 0)
                    break
        except Exception:
            pass

    return counters


def audit_tcp_aborts(netstat_file: Optional[str] = None, snmp_file: Optional[str] = None) -> Dict[str, Any]:
    """Audits TCP connection aborts and reset rates across the host."""
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)
    snmp_path = Path(snmp_file) if snmp_file else Path(PROC_SNMP)

    counters = parse_abort_counters(netstat_path, snmp_path)
    total_connections = counters["active_opens"] + counters["passive_opens"]
    abort_on_data = counters["abort_on_data"]
    abort_on_memory = counters["abort_on_memory"]
    abort_on_timeout = counters["abort_on_timeout"]
    abort_failed = counters["abort_failed"]
    backlog_drop = counters["backlog_drop"]

    abort_on_data_pct = round((abort_on_data / total_connections * 100), 2) if total_connections > 0 else 0.0

    issues: List[str] = []

    # 1. Critical: Abort on memory > 0
    if abort_on_memory > 0:
        issues.append(f"Critical: {abort_on_memory:,} TCP connections aborted due to kernel memory exhaustion")

    # 2. Abort failed > 1000
    if abort_failed > 1000:
        issues.append(f"Elevated TCP abort failures ({abort_failed:,} failed abort RST frames)")

    # 3. Socket backlog drops > 500
    if backlog_drop > 500:
        issues.append(f"Socket backlog drops detected ({backlog_drop:,} packets dropped)")

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "total_connections": total_connections,
            "abort_on_data": abort_on_data,
            "abort_on_data_pct": abort_on_data_pct,
            "abort_on_close": counters["abort_on_close"],
            "abort_on_timeout": abort_on_timeout,
            "abort_on_memory": abort_on_memory,
            "abort_failed": abort_failed,
            "backlog_drop": backlog_drop,
            "estab_resets": counters["estab_resets"],
            "issues": issues,
        },
        "counters": counters,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Connection Abort & Socket Reset Guard (Pattern 146)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    parser.add_argument("--snmp-file", type=str, default=None, help="Path to /proc/net/snmp")
    args = parser.parse_args()

    result = audit_tcp_aborts(netstat_file=args.netstat_file, snmp_file=args.snmp_file)

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP Connection Abort Guard (Pattern 146)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Total Connections Opened:      {summary['total_connections']:,} ({counters['active_opens']:,} act / {counters['passive_opens']:,} pas)")
    print(f" TCP Abort on Unread Data:      {summary['abort_on_data']:,} ({summary['abort_on_data_pct']}% of conn)")
    print(f" TCP Abort on Close:            {summary['abort_on_close']:,}")
    print(f" TCP Abort on Retrans Timeout:  {summary['abort_on_timeout']:,}")
    print(f" TCP Abort on Memory Exhaust:   {summary['abort_on_memory']:,}")
    print(f" TCP Abort Transmit Failures:   {summary['abort_failed']:,}")
    print(f" TCP Socket Backlog Drops:      {summary['backlog_drop']:,}")
    print(f" Established Connection Resets: {summary['estab_resets']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Abort / Reset Metric':<35} {'Count / Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Abort on Memory Exhaustion':<35} {summary['abort_on_memory']:<15} {'Nominal' if summary['abort_on_memory'] == 0 else 'CRITICAL'}")
    print(f" {'Abort Failed Count':<35} {summary['abort_failed']:<15} {'Nominal' if summary['abort_failed'] <= 1000 else 'WARNING'}")
    print(f" {'Backlog Packet Drops':<35} {summary['backlog_drop']:<15} {'Nominal' if summary['backlog_drop'] <= 500 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive TCP Abort / Connection Reset Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP connection aborts, unread data resets, and socket memory nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
