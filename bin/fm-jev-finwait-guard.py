#!/usr/bin/env python3
"""
fm-jev-finwait-guard.py - Jev Multi-Agent Host Network TCP FIN-WAIT-2 Orphan & Lingering Socket Guard (Pattern 149)

Audits Linux TCP FIN-WAIT-2 sockets, orphan sockets, and closing connection hygiene:
  - /proc/sys/net/ipv4/tcp_fin_timeout (seconds before dropping socket in FIN-WAIT-2 state)
  - /proc/sys/net/ipv4/tcp_max_orphans (maximum permitted unattached orphan sockets)
  - /proc/net/sockstat TCP orphan count and socket allocation
  - Active FIN_WAIT1 (04) and FIN_WAIT2 (05) socket counts from /proc/net/tcp and /proc/net/tcp6
  - CLOSE_WAIT (08) socket counts (sockets waiting for local application close)

In high-concurrency multi-agent microservice meshes, ungraceful remote disconnections can accumulate
orphaned FIN-WAIT-2 sockets, consuming kernel socket memory structures if tcp_fin_timeout is unconstrained.
Similarly, lingering CLOSE_WAIT sockets signal local agent applications failing to invoke close() on EOF.

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

PROC_NET_TCP = "/proc/net/tcp"
PROC_NET_TCP6 = "/proc/net/tcp6"
PROC_SOCKSTAT = "/proc/net/sockstat"
SYSCTL_FIN_TIMEOUT = "/proc/sys/net/ipv4/tcp_fin_timeout"
SYSCTL_MAX_ORPHANS = "/proc/sys/net/ipv4/tcp_max_orphans"

STATE_MAP = {
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


def read_int_file(path: Path, default: int = 0) -> int:
    """Safely reads an integer from a sysctl file."""
    if not path.is_file():
        return default
    try:
        return int(path.read_text().strip())
    except Exception:
        return default


def parse_sockstat_orphans(sockstat_path: Path) -> Dict[str, int]:
    """Parses orphan and inuse counts from /proc/net/sockstat."""
    metrics = {"inuse": 0, "orphan": 0, "tw": 0, "alloc": 0}
    if not sockstat_path.is_file():
        return metrics

    try:
        lines = sockstat_path.read_text().splitlines()
        for line in lines:
            if line.startswith("TCP:"):
                parts = line.split()
                for idx, part in enumerate(parts):
                    if part == "inuse" and idx + 1 < len(parts):
                        metrics["inuse"] = int(parts[idx + 1])
                    elif part == "orphan" and idx + 1 < len(parts):
                        metrics["orphan"] = int(parts[idx + 1])
                    elif part == "tw" and idx + 1 < len(parts):
                        metrics["tw"] = int(parts[idx + 1])
                    elif part == "alloc" and idx + 1 < len(parts):
                        metrics["alloc"] = int(parts[idx + 1])
                break
    except Exception:
        pass
    return metrics


def parse_tcp_states(tcp_path: Path) -> Dict[str, int]:
    """Parses socket state counts from /proc/net/tcp or tcp6."""
    state_counts: Dict[str, int] = {name: 0 for name in STATE_MAP.values()}
    state_counts["TOTAL"] = 0
    if not tcp_path.is_file():
        return state_counts

    try:
        lines = tcp_path.read_text().splitlines()[1:]
        for line in lines:
            parts = line.split()
            if len(parts) > 3:
                state_counts["TOTAL"] += 1
                st = parts[3].upper()
                name = STATE_MAP.get(st, "UNKNOWN")
                if name in state_counts:
                    state_counts[name] += 1
    except Exception:
        pass
    return state_counts


def audit_finwait(
    tcp_file: Optional[str] = None,
    tcp6_file: Optional[str] = None,
    sockstat_file: Optional[str] = None,
    fin_timeout_file: Optional[str] = None,
    max_orphans_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TCP FIN-WAIT-2 sockets, orphans, and close states."""
    t_file = Path(tcp_file) if tcp_file else Path(PROC_NET_TCP)
    t6_file = Path(tcp6_file) if tcp6_file else Path(PROC_NET_TCP6)
    s_file = Path(sockstat_file) if sockstat_file else Path(PROC_SOCKSTAT)

    timeout_path = Path(fin_timeout_file) if fin_timeout_file else Path(SYSCTL_FIN_TIMEOUT)
    orphans_path = Path(max_orphans_file) if max_orphans_file else Path(SYSCTL_MAX_ORPHANS)

    fin_timeout = read_int_file(timeout_path, default=60)
    max_orphans = read_int_file(orphans_path, default=262144)

    sockstat = parse_sockstat_orphans(s_file)
    states4 = parse_tcp_states(t_file)
    states6 = parse_tcp_states(t6_file)

    fin_wait1 = states4.get("FIN_WAIT1", 0) + states6.get("FIN_WAIT1", 0)
    fin_wait2 = states4.get("FIN_WAIT2", 0) + states6.get("FIN_WAIT2", 0)
    close_wait = states4.get("CLOSE_WAIT", 0) + states6.get("CLOSE_WAIT", 0)
    closing = states4.get("CLOSING", 0) + states6.get("CLOSING", 0)
    last_ack = states4.get("LAST_ACK", 0) + states6.get("LAST_ACK", 0)

    orphan_count = sockstat["orphan"]
    orphan_util_pct = round((orphan_count / max_orphans * 100), 2) if max_orphans > 0 else 0.0

    issues: List[str] = []

    # 1. FIN timeout excessive (> 120s)
    if fin_timeout > 120:
        issues.append(f"Excessive tcp_fin_timeout ({fin_timeout}s > 120s); lingering FIN-WAIT-2 memory overhead")

    # 2. Orphan sockets approaching capacity (> 50%)
    if orphan_util_pct > 50.0:
        issues.append(f"High orphan socket saturation ({orphan_count:,} / {max_orphans:,}, {orphan_util_pct}%)")

    # 3. Massive accumulation of FIN-WAIT-2 (> 2000)
    if fin_wait2 > 2000:
        issues.append(f"Excessive lingering FIN-WAIT-2 sockets ({fin_wait2:,} sockets)")

    # 4. Massive accumulation of CLOSE-WAIT (> 500)
    if close_wait > 500:
        issues.append(f"Elevated CLOSE-WAIT sockets ({close_wait:,} sockets); local process socket descriptor leak")

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "tcp_fin_timeout_sec": fin_timeout,
            "tcp_max_orphans": max_orphans,
            "orphan_count": orphan_count,
            "orphan_util_pct": orphan_util_pct,
            "fin_wait1_sockets": fin_wait1,
            "fin_wait2_sockets": fin_wait2,
            "close_wait_sockets": close_wait,
            "closing_sockets": closing,
            "last_ack_sockets": last_ack,
            "total_tcp_inuse": sockstat["inuse"],
            "issues": issues,
        },
        "sockstat": sockstat,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP FIN-WAIT-2 Orphan & Lingering Socket Guard (Pattern 149)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--tcp-file", type=str, default=None, help="Path to /proc/net/tcp")
    parser.add_argument("--tcp6-file", type=str, default=None, help="Path to /proc/net/tcp6")
    parser.add_argument("--sockstat-file", type=str, default=None, help="Path to /proc/net/sockstat")
    parser.add_argument("--timeout-file", type=str, default=None, help="Path to tcp_fin_timeout")
    parser.add_argument("--max-orphans-file", type=str, default=None, help="Path to tcp_max_orphans")
    args = parser.parse_args()

    result = audit_finwait(
        tcp_file=args.tcp_file,
        tcp6_file=args.tcp6_file,
        sockstat_file=args.sockstat_file,
        fin_timeout_file=args.timeout_file,
        max_orphans_file=args.max_orphans_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP FIN-WAIT-2 & Orphan Socket Guard (Pattern 149)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" tcp_fin_timeout:               {summary['tcp_fin_timeout_sec']}s")
    print(f" tcp_max_orphans:               {summary['tcp_max_orphans']:,}")
    print(f" Active Orphan Sockets:         {summary['orphan_count']:,} ({summary['orphan_util_pct']}% utilization)")
    print(f" Sockets in FIN_WAIT1:          {summary['fin_wait1_sockets']:,}")
    print(f" Sockets in FIN_WAIT2:          {summary['fin_wait2_sockets']:,}")
    print(f" Sockets in CLOSE_WAIT:         {summary['close_wait_sockets']:,}")
    print(f" Sockets in CLOSING / LAST_ACK: {summary['closing_sockets'] + summary['last_ack_sockets']:,}")
    print(f" Total TCP In-Use Sockets:      {summary['total_tcp_inuse']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Socket State / Parameter':<35} {'Count / Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    timeout_str = f"{summary['tcp_fin_timeout_sec']}s"
    orphan_str = f"{summary['orphan_util_pct']}%"
    print(f" {'FIN-WAIT-2 Timeout':<35} {timeout_str:<15} {'Nominal' if summary['tcp_fin_timeout_sec'] <= 120 else 'WARNING'}")
    print(f" {'Orphan Socket Saturation':<35} {orphan_str:<15} {'Nominal' if summary['orphan_util_pct'] <= 50.0 else 'WARNING'}")
    print(f" {'FIN_WAIT2 Sockets':<35} {summary['fin_wait2_sockets']:<15} {'Nominal' if summary['fin_wait2_sockets'] <= 2000 else 'WARNING'}")
    print(f" {'CLOSE_WAIT Sockets':<35} {summary['close_wait_sockets']:<15} {'Nominal' if summary['close_wait_sockets'] <= 500 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive TCP FIN-WAIT / Orphan Socket Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP FIN-WAIT-2 timeouts, orphan sockets, and closing connection states nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
