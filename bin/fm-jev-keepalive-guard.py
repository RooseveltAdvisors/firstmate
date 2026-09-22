#!/usr/bin/env python3
"""
fm-jev-keepalive-guard.py - Jev Multi-Agent Host Network TCP Keepalive & Silent Dead Peer Detection Guard (Pattern 148)

Audits Linux TCP keepalive settings, active keepalive timers, and socket dead peer detection:
  - /proc/sys/net/ipv4/tcp_keepalive_time (idle time in seconds before sending keepalive probes)
  - /proc/sys/net/ipv4/tcp_keepalive_intvl (interval in seconds between keepalive probes)
  - /proc/sys/net/ipv4/tcp_keepalive_probes (unanswered probe count before terminating connection)
  - Total teardown duration: time + (intvl * probes)
  - Active socket keepalive timers from /proc/net/tcp and /proc/net/tcp6 (timer type 02)
  - Retransmission timeouts from /proc/net/netstat (TCPAbortOnTimeout)

In long-running multi-agent clusters with persistent streaming sockets, overly long keepalive timeouts
(e.g. 7200s / 2 hours default) can leave dead peer sockets lingering across intermediate NAT gateways
for hours, causing resource leakage and connection slot starvation.

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
PROC_NETSTAT = "/proc/net/netstat"
SYSCTL_KEEPALIVE_TIME = "/proc/sys/net/ipv4/tcp_keepalive_time"
SYSCTL_KEEPALIVE_INTVL = "/proc/sys/net/ipv4/tcp_keepalive_intvl"
SYSCTL_KEEPALIVE_PROBES = "/proc/sys/net/ipv4/tcp_keepalive_probes"


def read_int_file(path: Path, default: int = 0) -> int:
    """Safely reads an integer from a sysctl file."""
    if not path.is_file():
        return default
    try:
        return int(path.read_text().strip())
    except Exception:
        return default


def parse_tcp_timers(tcp_path: Path) -> Dict[str, int]:
    """Parses socket timer types from /proc/net/tcp or tcp6."""
    # Timer types: 00=off, 01=retransmit, 02=keepalive, 03=TIME_WAIT, 04=zero window probe
    counts: Dict[str, int] = {
        "timer_off": 0,
        "timer_retransmit": 0,
        "timer_keepalive": 0,
        "timer_timewait": 0,
        "timer_winprobe": 0,
        "total_sockets": 0,
    }
    if not tcp_path.is_file():
        return counts

    try:
        lines = tcp_path.read_text().splitlines()[1:]
        for line in lines:
            parts = line.split()
            if len(parts) > 5:
                counts["total_sockets"] += 1
                tr = parts[5].split(":")[0]
                if tr == "00":
                    counts["timer_off"] += 1
                elif tr == "01":
                    counts["timer_retransmit"] += 1
                elif tr == "02":
                    counts["timer_keepalive"] += 1
                elif tr == "03":
                    counts["timer_timewait"] += 1
                elif tr == "04":
                    counts["timer_winprobe"] += 1
    except Exception:
        pass

    return counts


def parse_netstat_timeouts(netstat_path: Path) -> int:
    """Parses TCPAbortOnTimeout from /proc/net/netstat."""
    if not netstat_path.is_file():
        return 0
    try:
        lines = netstat_path.read_text().splitlines()
        for i in range(0, len(lines) - 1, 2):
            header_line = lines[i].strip()
            data_line = lines[i + 1].strip()
            if header_line.startswith("TcpExt:") and data_line.startswith("TcpExt:"):
                headers = header_line.split()[1:]
                values = data_line.split()[1:]
                header_map = {h: int(v) for h, v in zip(headers, values) if v.isdigit()}
                return header_map.get("TCPAbortOnTimeout", 0)
    except Exception:
        pass
    return 0


def audit_keepalive(
    tcp_file: Optional[str] = None,
    tcp6_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
    keepalive_time_file: Optional[str] = None,
    keepalive_intvl_file: Optional[str] = None,
    keepalive_probes_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TCP keepalive parameters and active socket keepalive timers."""
    t_file = Path(tcp_file) if tcp_file else Path(PROC_NET_TCP)
    t6_file = Path(tcp6_file) if tcp6_file else Path(PROC_NET_TCP6)
    n_file = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)

    time_path = Path(keepalive_time_file) if keepalive_time_file else Path(SYSCTL_KEEPALIVE_TIME)
    intvl_path = Path(keepalive_intvl_file) if keepalive_intvl_file else Path(SYSCTL_KEEPALIVE_INTVL)
    probes_path = Path(keepalive_probes_file) if keepalive_probes_file else Path(SYSCTL_KEEPALIVE_PROBES)

    ka_time = read_int_file(time_path, default=7200)
    ka_intvl = read_int_file(intvl_path, default=75)
    ka_probes = read_int_file(probes_path, default=9)

    total_teardown_sec = ka_time + (ka_intvl * ka_probes)
    total_teardown_hours = round(total_teardown_sec / 3600.0, 2)

    timers4 = parse_tcp_timers(t_file)
    timers6 = parse_tcp_timers(t6_file)

    total_keepalive_sockets = timers4["timer_keepalive"] + timers6["timer_keepalive"]
    total_sockets = timers4["total_sockets"] + timers6["total_sockets"]
    abort_on_timeout = parse_netstat_timeouts(n_file)

    issues: List[str] = []

    # 1. Total teardown excessive (> 4 hours)
    if total_teardown_hours > 4.0:
        issues.append(f"Excessive TCP keepalive teardown duration ({total_teardown_hours}h > 4.0h)")

    # 2. Keepalive probes == 0
    if ka_probes <= 0:
        issues.append("tcp_keepalive_probes is 0; dead peers will never be disconnected")

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "tcp_keepalive_time_sec": ka_time,
            "tcp_keepalive_intvl_sec": ka_intvl,
            "tcp_keepalive_probes": ka_probes,
            "total_teardown_sec": total_teardown_sec,
            "total_teardown_hours": total_teardown_hours,
            "active_keepalive_sockets": total_keepalive_sockets,
            "total_sockets": total_sockets,
            "abort_on_timeout": abort_on_timeout,
            "issues": issues,
        },
        "ipv4_timers": timers4,
        "ipv6_timers": timers6,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Keepalive & Silent Dead Peer Detection Guard (Pattern 148)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--tcp-file", type=str, default=None, help="Path to /proc/net/tcp")
    parser.add_argument("--tcp6-file", type=str, default=None, help="Path to /proc/net/tcp6")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    parser.add_argument("--time-file", type=str, default=None, help="Path to tcp_keepalive_time")
    parser.add_argument("--intvl-file", type=str, default=None, help="Path to tcp_keepalive_intvl")
    parser.add_argument("--probes-file", type=str, default=None, help="Path to tcp_keepalive_probes")
    args = parser.parse_args()

    result = audit_keepalive(
        tcp_file=args.tcp_file,
        tcp6_file=args.tcp6_file,
        netstat_file=args.netstat_file,
        keepalive_time_file=args.time_file,
        keepalive_intvl_file=args.intvl_file,
        keepalive_probes_file=args.probes_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP Keepalive Guard (Pattern 148)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" tcp_keepalive_time:            {summary['tcp_keepalive_time_sec']}s ({summary['tcp_keepalive_time_sec'] / 60:.1f} min)")
    print(f" tcp_keepalive_intvl:           {summary['tcp_keepalive_intvl_sec']}s")
    print(f" tcp_keepalive_probes:          {summary['tcp_keepalive_probes']} probes")
    print(f" Max Dead Peer Teardown Time:   {summary['total_teardown_sec']}s (~{summary['total_teardown_hours']} hours)")
    print(f" Active Keepalive Sockets:      {summary['active_keepalive_sockets']:,} / {summary['total_sockets']:,} total sockets")
    print(f" Retransmission Timeouts (RTO): {summary['abort_on_timeout']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Keepalive Parameter':<35} {'Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    hours_str = f"{summary['total_teardown_hours']} hours"
    print(f" {'Max Teardown Latency':<35} {hours_str:<15} {'Nominal' if summary['total_teardown_hours'] <= 4.0 else 'WARNING'}")
    print(f" {'Probe Count':<35} {summary['tcp_keepalive_probes']:<15} {'Nominal' if summary['tcp_keepalive_probes'] > 0 else 'WARNING'}")
    print(f" {'Active Keepalive Sockets':<35} {summary['active_keepalive_sockets']:<15} {'Nominal'}")

    if summary["issues"]:
        print("\nActive TCP Keepalive Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP keepalive parameters, active timers, and peer detection nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
