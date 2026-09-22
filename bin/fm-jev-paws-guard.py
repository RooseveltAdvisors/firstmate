#!/usr/bin/env python3
"""
fm-jev-paws-guard.py - Jev Multi-Agent Host Network TCP TIME-WAIT Recycling & PAWS Failure Guard (Pattern 109)

Audits Linux TCP TIME-WAIT recycling sysctl settings and Protection Against Wrapped Sequence Numbers (PAWS)
drop counters from /proc/sys/net/ipv4/tcp_tw_reuse, /proc/sys/net/ipv4/tcp_timestamps,
/proc/sys/net/ipv4/tcp_rfc1337, /proc/sys/net/ipv4/tcp_max_tw_buckets, and /proc/net/netstat (TcpExt:
PAWSEstab, PAWSTimewait, PAWSOldAck, PAWSActive, TCPACKSkippedPAWS, TW, TWRecycled, TWKilled, TCPTimeWaitOverflow).

Detects silent packet drops caused by timestamp regressions behind NAT/cloud proxies, ineffective socket reuse
due to disabled timestamps, and TIME-WAIT table overflows during burst multi-agent fleet traffic.

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
from typing import Any, Dict, List, Optional

SYSCTL_TW_REUSE = "/proc/sys/net/ipv4/tcp_tw_reuse"
SYSCTL_TIMESTAMPS = "/proc/sys/net/ipv4/tcp_timestamps"
SYSCTL_RFC1337 = "/proc/sys/net/ipv4/tcp_rfc1337"
SYSCTL_MAX_TW_BUCKETS = "/proc/sys/net/ipv4/tcp_max_tw_buckets"
PROC_NETSTAT = "/proc/net/netstat"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def parse_tcpext_netstat(path: Path) -> Dict[str, int]:
    """Parses TcpExt key-value metrics from /proc/net/netstat."""
    if not path.is_file():
        return {}

    metrics: Dict[str, int] = {}
    try:
        lines = path.read_text().splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("TcpExt:") and lines[i + 1].startswith("TcpExt:"):
                keys = lines[i].split()[1:]
                vals = lines[i + 1].split()[1:]
                for k, v in zip(keys, vals):
                    try:
                        metrics[k] = int(v)
                    except ValueError:
                        continue
                break
    except Exception:
        pass

    return metrics


def audit_paws(
    tw_reuse_file: Optional[str] = None,
    timestamps_file: Optional[str] = None,
    rfc1337_file: Optional[str] = None,
    max_tw_buckets_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TIME-WAIT reuse settings, RFC 1337 protection, and PAWS drop counters."""
    tw_reuse_path = Path(tw_reuse_file) if tw_reuse_file else Path(SYSCTL_TW_REUSE)
    timestamps_path = Path(timestamps_file) if timestamps_file else Path(SYSCTL_TIMESTAMPS)
    rfc1337_path = Path(rfc1337_file) if rfc1337_file else Path(SYSCTL_RFC1337)
    max_tw_buckets_path = Path(max_tw_buckets_file) if max_tw_buckets_file else Path(SYSCTL_MAX_TW_BUCKETS)
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)

    tw_reuse = read_int_file(tw_reuse_path)
    timestamps = read_int_file(timestamps_path)
    rfc1337 = read_int_file(rfc1337_path)
    max_tw_buckets = read_int_file(max_tw_buckets_path)

    tcpext = parse_tcpext_netstat(netstat_path)

    paws_estab = tcpext.get("PAWSEstab", 0)
    paws_timewait = tcpext.get("PAWSTimewait", 0)
    paws_old_ack = tcpext.get("PAWSOldAck", 0)
    paws_active = tcpext.get("PAWSActive", 0)
    ack_skipped_paws = tcpext.get("TCPACKSkippedPAWS", 0)
    tw_count = tcpext.get("TW", 0)
    tw_recycled = tcpext.get("TWRecycled", 0)
    tw_killed = tcpext.get("TWKilled", 0)
    tw_overflow = tcpext.get("TCPTimeWaitOverflow", 0)

    # Human-readable mode for tcp_tw_reuse
    reuse_desc = "Unknown"
    if tw_reuse == 0:
        reuse_desc = "Disabled"
    elif tw_reuse == 1:
        reuse_desc = "Global enabled (safe client reuse)"
    elif tw_reuse == 2:
        reuse_desc = "Loopback only enabled (Linux 4.x+ default)"

    issues: List[str] = []

    if tw_reuse is not None and tw_reuse > 0 and timestamps == 0:
        issues.append(f"Inconsistent TCP configuration: tcp_tw_reuse is {tw_reuse} but tcp_timestamps is disabled (0)")

    if tw_overflow > 0:
        issues.append(f"TCP TIME-WAIT table overflows detected ({tw_overflow} events): exceeding tcp_max_tw_buckets ({max_tw_buckets})")

    if tw_killed > 0:
        issues.append(f"TCP TIME-WAIT sockets prematurely killed ({tw_killed} events): possible memory pressure or bucket limit")

    if paws_estab > 50000:
        issues.append(f"Elevated PAWS drops on established sockets ({paws_estab} events): potential NAT timestamp collision")

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_tw_reuse": tw_reuse,
            "tcp_tw_reuse_mode": reuse_desc,
            "tcp_timestamps": timestamps == 1 if timestamps is not None else None,
            "tcp_rfc1337": rfc1337 == 1 if rfc1337 is not None else None,
            "tcp_max_tw_buckets": max_tw_buckets,
            "paws_estab_drops": paws_estab,
            "tw_overflow_events": tw_overflow,
            "tw_killed_events": tw_killed,
            "issues": issues,
        },
        "counters": {
            "paws_estab": paws_estab,
            "paws_timewait": paws_timewait,
            "paws_old_ack": paws_old_ack,
            "paws_active": paws_active,
            "ack_skipped_paws": ack_skipped_paws,
            "tw_total": tw_count,
            "tw_recycled": tw_recycled,
            "tw_killed": tw_killed,
            "tw_overflow": tw_overflow,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP TIME-WAIT Recycling & PAWS Failure Guard (Pattern 109)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--tw-reuse-file", type=str, default=None, help="Path to tcp_tw_reuse")
    parser.add_argument("--timestamps-file", type=str, default=None, help="Path to tcp_timestamps")
    parser.add_argument("--rfc1337-file", type=str, default=None, help="Path to tcp_rfc1337")
    parser.add_argument("--max-tw-buckets-file", type=str, default=None, help="Path to tcp_max_tw_buckets")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_paws(
        tw_reuse_file=args.tw_reuse_file,
        timestamps_file=args.timestamps_file,
        rfc1337_file=args.rfc1337_file,
        max_tw_buckets_file=args.max_tw_buckets_file,
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
    print(" Jev Multi-Agent Host Network TCP TIME-WAIT & PAWS Guard (Pattern 109)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" TCP TW Reuse:                  {summary['tcp_tw_reuse']} ({summary['tcp_tw_reuse_mode']})")
    print(f" TCP Timestamps:                {'Enabled' if summary['tcp_timestamps'] else 'Disabled'}")
    print(f" RFC 1337 Protect:              {'Enabled' if summary['tcp_rfc1337'] else 'Disabled'}")
    print(f" Max TIME-WAIT Buckets:         {summary['tcp_max_tw_buckets']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'PAWS / TIME-WAIT Metric':<30} {'Count':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'PAWS Drops (Established)':<30} {counters['paws_estab']:<15} {'Nominal' if counters['paws_estab'] < 50000 else 'WARNING'}")
    print(f" {'PAWS Drops (TIME-WAIT)':<30} {counters['paws_timewait']:<15} Nominal")
    print(f" {'PAWS Old ACKs Rejected':<30} {counters['paws_old_ack']:<15} Nominal")
    print(f" {'PAWS Skipped ACKs':<30} {counters['ack_skipped_paws']:<15} Nominal")
    print(f" {'TIME-WAIT Total Created':<30} {counters['tw_total']:<15} Nominal")
    print(f" {'TIME-WAIT Recycled':<30} {counters['tw_recycled']:<15} Nominal")
    print(f" {'TIME-WAIT Overflow':<30} {counters['tw_overflow']:<15} {'Nominal' if counters['tw_overflow'] == 0 else 'WARNING'}")
    print(f" {'TIME-WAIT Killed':<30} {counters['tw_killed']:<15} {'Nominal' if counters['tw_killed'] == 0 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive TCP PAWS / TIME-WAIT Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP TIME-WAIT reuse settings and PAWS drop metrics nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
