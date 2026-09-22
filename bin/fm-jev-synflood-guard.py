#!/usr/bin/env python3
"""
fm-jev-synflood-guard.py - Jev Multi-Agent Host Network TCP SYN-Flood Drop & Request Queue Eviction Guard (Pattern 139)

Audits Linux TCP SYN queue capacity (/proc/sys/net/ipv4/tcp_max_syn_backlog),
SYN cookie fallback protection (/proc/sys/net/ipv4/tcp_syncookies),
SYN-ACK retry limits (/proc/sys/net/ipv4/tcp_synack_retries),
and half-open connection drop / eviction counters from /proc/net/netstat
(TCPReqQFullDoCookies, TCPReqQFullDrop, TCPSynRetrans, EmbryonicRsts, SyncookiesSent/Recv/Failed).

Under high agent connection bursts, tool invocation floods, and multi-threaded RPC handshakes,
an exhausted SYN queue silently drops incoming TCP SYNs or triggers costly SYN cookie CPU verification.

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

SYSCTL_MAX_SYN_BACKLOG = "/proc/sys/net/ipv4/tcp_max_syn_backlog"
SYSCTL_SYNCOOKIES = "/proc/sys/net/ipv4/tcp_syncookies"
SYSCTL_SYNACK_RETRIES = "/proc/sys/net/ipv4/tcp_synack_retries"

PROC_NETSTAT = "/proc/net/netstat"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def parse_netstat_syn_counters(netstat_path: Path) -> Dict[str, int]:
    """Parses SYN queue and cookie counters from /proc/net/netstat."""
    counters: Dict[str, int] = {
        "req_q_full_cookies": 0,
        "req_q_full_drop": 0,
        "syn_retrans": 0,
        "embryonic_rsts": 0,
        "syncookies_sent": 0,
        "syncookies_recv": 0,
        "syncookies_failed": 0,
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

                counters["req_q_full_cookies"] = header_map.get("TCPReqQFullDoCookies", 0)
                counters["req_q_full_drop"] = header_map.get("TCPReqQFullDrop", 0)
                counters["syn_retrans"] = header_map.get("TCPSynRetrans", 0)
                counters["embryonic_rsts"] = header_map.get("EmbryonicRsts", 0)
                counters["syncookies_sent"] = header_map.get("SyncookiesSent", 0)
                counters["syncookies_recv"] = header_map.get("SyncookiesRecv", 0)
                counters["syncookies_failed"] = header_map.get("SyncookiesFailed", 0)
                break
    except Exception:
        pass

    return counters


def audit_synflood(
    max_syn_backlog_file: Optional[str] = None,
    syncookies_file: Optional[str] = None,
    synack_retries_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TCP SYN queue backlog and SYN drop counters."""
    backlog_path = Path(max_syn_backlog_file) if max_syn_backlog_file else Path(SYSCTL_MAX_SYN_BACKLOG)
    cookies_path = Path(syncookies_file) if syncookies_file else Path(SYSCTL_SYNCOOKIES)
    retries_path = Path(synack_retries_file) if synack_retries_file else Path(SYSCTL_SYNACK_RETRIES)
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)

    max_syn_backlog = read_int_file(backlog_path)
    if max_syn_backlog is None:
        max_syn_backlog = 4096

    syncookies = read_int_file(cookies_path)
    if syncookies is None:
        syncookies = 1

    synack_retries = read_int_file(retries_path)
    if synack_retries is None:
        synack_retries = 5

    counters = parse_netstat_syn_counters(netstat_path)

    issues: List[str] = []

    if syncookies == 0:
        issues.append("tcp_syncookies is disabled (0); system vulnerable to SYN flood denial-of-service")

    if max_syn_backlog < 1024:
        issues.append(f"tcp_max_syn_backlog ({max_syn_backlog}) is below recommended 1024 limit")

    if counters["req_q_full_drop"] > 0:
        issues.append(
            f"SYN request queue drops detected ({counters['req_q_full_drop']} incoming connections rejected)"
        )

    if counters["syncookies_failed"] > 100:
        issues.append(
            f"High SYN cookie validation failures detected ({counters['syncookies_failed']} invalid cookies)"
        )

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "tcp_max_syn_backlog": max_syn_backlog,
            "tcp_syncookies": syncookies,
            "tcp_synack_retries": synack_retries,
            "issues": issues,
        },
        "counters": counters,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP SYN-Flood Drop & Request Queue Eviction Guard (Pattern 139)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--backlog-file", type=str, default=None, help="Path to tcp_max_syn_backlog")
    parser.add_argument("--syncookies-file", type=str, default=None, help="Path to tcp_syncookies")
    parser.add_argument("--synack-retries-file", type=str, default=None, help="Path to tcp_synack_retries")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_synflood(
        max_syn_backlog_file=args.backlog_file,
        syncookies_file=args.syncookies_file,
        synack_retries_file=args.synack_retries_file,
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
    print(" Jev Multi-Agent Host Network TCP SYN-Flood & Request Queue Guard (Pattern 139)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" SYN Backlog Capacity:          {summary['tcp_max_syn_backlog']:,} entries (tcp_max_syn_backlog)")
    print(f" SYN Cookie Fallback:           {'Enabled (1)' if summary['tcp_syncookies'] == 1 else 'Disabled (0)'} (tcp_syncookies)")
    print(f" SYN-ACK Retry Limit:           {summary['tcp_synack_retries']} retries (tcp_synack_retries)")
    print(f" Request Queue Full Drops:      {counters['req_q_full_drop']:,}")
    print(f" Request Queue Full Cookies:    {counters['req_q_full_cookies']:,}")
    print(f" SYN Retransmissions:           {counters['syn_retrans']:,}")
    print(f" Embryonic Connection Resets:   {counters['embryonic_rsts']:,}")
    print(f" SYN Cookies Sent / Recv:       {counters['syncookies_sent']:,} / {counters['syncookies_recv']:,}")
    print(f" SYN Cookie Verification Fails: {counters['syncookies_failed']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'SYN Queue / Drop Metric':<35} {'Count / Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'tcp_syncookies':<35} {summary['tcp_syncookies']:<15} {'Nominal' if summary['tcp_syncookies'] == 1 else 'WARNING'}")
    print(f" {'tcp_max_syn_backlog':<35} {summary['tcp_max_syn_backlog']:<15} {'Nominal' if summary['tcp_max_syn_backlog'] >= 1024 else 'WARNING'}")
    print(f" {'Request Queue Drops':<35} {counters['req_q_full_drop']:<15} {'Nominal' if counters['req_q_full_drop'] == 0 else 'WARNING'}")
    print(f" {'SYN Cookie Failures':<35} {counters['syncookies_failed']:<15} {'Nominal' if counters['syncookies_failed'] <= 100 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive TCP SYN Queue / SYN-Flood Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP SYN backlog parameters, SYN cookies, and queue drop counters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
