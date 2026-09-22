#!/usr/bin/env python3
"""
fm-jev-finwait-guard.py - Jev Multi-Agent Host Network TCP FIN-WAIT-2 & Orphan Socket Guard (Pattern 108)

Audits Linux TCP FIN-WAIT-2 teardown states, orphan socket capacity, and fin_timeout limits from
/proc/sys/net/ipv4/tcp_fin_timeout, tcp_max_orphans, /proc/net/sockstat, and /proc/net/tcp / tcp6.

Detects lingering half-closed sockets, unresponsive peer teardown hangs, orphan socket accumulation,
and descriptor exhaustion across high-churn multi-agent RPC lifecycles, HTTP client streams, and API gateways.

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

SYSCTL_FIN_TIMEOUT = "/proc/sys/net/ipv4/tcp_fin_timeout"
SYSCTL_MAX_ORPHANS = "/proc/sys/net/ipv4/tcp_max_orphans"
PROC_SOCKSTAT = "/proc/net/sockstat"
PROC_TCP = "/proc/net/tcp"
PROC_TCP6 = "/proc/net/tcp6"

TCP_STATE_MAP = {
    "01": "ESTABLISHED",
    "02": "SYN_SENT",
    "03": "SYN_RECV",
    "04": "FIN_WAIT1",
    "05": "FIN_WAIT2",
    "06": "TIME_WAIT",
    "07": "CLOSE",
    "08": "CLOSE_WAIT",
    "09": "LAST_ACK",
    "0A": "LISTEN",
    "0B": "CLOSING",
}


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def parse_sockstat(path: Path) -> Dict[str, int]:
    """Parses TCP section inuse, orphan, tw, alloc, mem from /proc/net/sockstat."""
    if not path.is_file():
        return {}

    metrics: Dict[str, int] = {}
    try:
        for line in path.read_text().splitlines():
            if line.startswith("TCP:"):
                parts = line.split()
                # e.g. TCP: inuse 499 orphan 0 tw 227 alloc 522 mem 0
                for i in range(1, len(parts) - 1, 2):
                    try:
                        metrics[parts[i]] = int(parts[i + 1])
                    except (ValueError, IndexError):
                        continue
                break
    except Exception:
        pass

    return metrics


def count_tcp_teardown_states(paths: List[Path]) -> Dict[str, int]:
    """Parses /proc/net/tcp and /proc/net/tcp6 for connection states."""
    counts = {
        "FIN_WAIT1": 0,
        "FIN_WAIT2": 0,
        "CLOSING": 0,
        "LAST_ACK": 0,
        "TOTAL_SOCKS": 0,
    }

    for p in paths:
        if not p.is_file():
            continue
        try:
            lines = p.read_text().splitlines()
            for line in lines[1:]:  # skip header
                parts = line.split()
                if len(parts) >= 4:
                    counts["TOTAL_SOCKS"] += 1
                    hex_state = parts[3]
                    state_name = TCP_STATE_MAP.get(hex_state)
                    if state_name in counts:
                        counts[state_name] += 1
        except Exception:
            pass

    return counts


def audit_finwait(
    fin_timeout_file: Optional[str] = None,
    max_orphans_file: Optional[str] = None,
    sockstat_file: Optional[str] = None,
    tcp_file: Optional[str] = None,
    tcp6_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TCP FIN-WAIT-2 state, orphan sockets, and fin_timeout."""
    fin_path = Path(fin_timeout_file) if fin_timeout_file else Path(SYSCTL_FIN_TIMEOUT)
    orphans_path = Path(max_orphans_file) if max_orphans_file else Path(SYSCTL_MAX_ORPHANS)
    sockstat_path = Path(sockstat_file) if sockstat_file else Path(PROC_SOCKSTAT)
    tcp_path = Path(tcp_file) if tcp_file else Path(PROC_TCP)
    tcp6_path = Path(tcp6_file) if tcp6_file else Path(PROC_TCP6)

    fin_timeout = read_int_file(fin_path)
    max_orphans = read_int_file(orphans_path)

    sockstat = parse_sockstat(sockstat_path)
    orphan_count = sockstat.get("orphan", 0)
    inuse_count = sockstat.get("inuse", 0)
    alloc_count = sockstat.get("alloc", 0)

    teardown_states = count_tcp_teardown_states([tcp_path, tcp6_path])

    fin_wait2_count = teardown_states["FIN_WAIT2"]
    fin_wait1_count = teardown_states["FIN_WAIT1"]
    closing_count = teardown_states["CLOSING"]
    last_ack_count = teardown_states["LAST_ACK"]

    orphan_util_pct = (orphan_count / max_orphans * 100.0) if max_orphans and max_orphans > 0 else 0.0

    issues: List[str] = []

    if fin_wait2_count > 200:
        issues.append(f"Elevated FIN-WAIT-2 socket accumulation ({fin_wait2_count} sockets): dead peers failing to send FIN")

    if orphan_count > 1000 or orphan_util_pct > 10.0:
        issues.append(f"High orphan TCP sockets ({orphan_count} / {max_orphans}, {orphan_util_pct:.1f}%): risk of kernel socket reset drops")

    if fin_timeout is not None and fin_timeout > 90:
        issues.append(f"High tcp_fin_timeout ({fin_timeout}s > 90s): half-closed sockets linger excessively before destruction")

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_fin_timeout_sec": fin_timeout,
            "tcp_max_orphans": max_orphans,
            "orphan_sockets": orphan_count,
            "orphan_utilization_pct": round(orphan_util_pct, 2),
            "fin_wait2_sockets": fin_wait2_count,
            "total_teardown_sockets": fin_wait1_count + fin_wait2_count + closing_count + last_ack_count,
            "issues": issues,
        },
        "states": {
            "fin_wait1": fin_wait1_count,
            "fin_wait2": fin_wait2_count,
            "closing": closing_count,
            "last_ack": last_ack_count,
            "tcp_inuse": inuse_count,
            "tcp_alloc": alloc_count,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP FIN-WAIT-2 & Orphan Socket Guard (Pattern 108)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--fin-timeout-file", type=str, default=None, help="Path to tcp_fin_timeout")
    parser.add_argument("--max-orphans-file", type=str, default=None, help="Path to tcp_max_orphans")
    parser.add_argument("--sockstat-file", type=str, default=None, help="Path to /proc/net/sockstat")
    parser.add_argument("--tcp-file", type=str, default=None, help="Path to /proc/net/tcp")
    parser.add_argument("--tcp6-file", type=str, default=None, help="Path to /proc/net/tcp6")
    args = parser.parse_args()

    result = audit_finwait(
        fin_timeout_file=args.fin_timeout_file,
        max_orphans_file=args.max_orphans_file,
        sockstat_file=args.sockstat_file,
        tcp_file=args.tcp_file,
        tcp6_file=args.tcp6_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    states = result["states"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP FIN-WAIT-2 & Orphan Guard (Pattern 108)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" TCP FIN Timeout:               {summary['tcp_fin_timeout_sec']}s")
    print(f" Max Orphans Capacity:          {summary['tcp_max_orphans']}")
    print(f" Orphan Sockets:                {summary['orphan_sockets']} ({summary['orphan_utilization_pct']}% utilization)")
    print(f" Total Teardown Sockets:        {summary['total_teardown_sockets']}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Socket Teardown State':<30} {'Count':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'FIN_WAIT_2 Sockets':<30} {states['fin_wait2']:<15} {'Nominal' if states['fin_wait2'] <= 200 else 'WARNING'}")
    print(f" {'FIN_WAIT_1 Sockets':<30} {states['fin_wait1']:<15} Nominal")
    print(f" {'CLOSING Sockets':<30} {states['closing']:<15} Nominal")
    print(f" {'LAST_ACK Sockets':<30} {states['last_ack']:<15} Nominal")
    print(f" {'Total TCP In-Use':<30} {states['tcp_inuse']:<15} Nominal")

    if summary["issues"]:
        print("\nActive FIN-WAIT / Orphan Socket Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP FIN-WAIT-2, teardown states, and orphan socket parameters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
