#!/usr/bin/env python3
"""
fm-jev-syncookie-guard.py - Jev Multi-Agent Host Network TCP SYN Cookie Guard (Pattern 118)

Audits Linux TCP SYN cookie parameters and queue saturation counters from
/proc/sys/net/ipv4/tcp_syncookies, /proc/sys/net/ipv4/tcp_max_syn_backlog, /proc/sys/net/core/somaxconn,
and /proc/net/netstat (TcpExt: SyncookiesSent, SyncookiesRecv, SyncookiesFailed, TCPReqQFullDoCookies,
TCPReqQFullDrop, ListenOverflows, ListenDrops).

Detects disabled SYN flood protection, premature SYN cookie hashing from undersized backlogs,
cookie validation failures, and request queue drop events during multi-agent concurrent IPC bursts.

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

SYSCTL_SYNCOOKIES = "/proc/sys/net/ipv4/tcp_syncookies"
SYSCTL_MAX_SYN_BACKLOG = "/proc/sys/net/ipv4/tcp_max_syn_backlog"
SYSCTL_SOMAXCONN = "/proc/sys/net/core/somaxconn"
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
                vals_raw = lines[i + 1].split()[1:]
                for k, v in zip(keys, vals_raw):
                    try:
                        metrics[k] = int(v)
                    except ValueError:
                        continue
                break
    except Exception:
        return {}

    return metrics


def audit_syncookie(
    syncookies_file: Optional[str] = None,
    backlog_file: Optional[str] = None,
    somaxconn_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host TCP SYN cookie and backlog health."""
    syncookies_p = Path(syncookies_file or SYSCTL_SYNCOOKIES)
    backlog_p = Path(backlog_file or SYSCTL_MAX_SYN_BACKLOG)
    somaxconn_p = Path(somaxconn_file or SYSCTL_SOMAXCONN)
    netstat_p = Path(netstat_file or PROC_NETSTAT)

    tcp_syncookies = read_int_file(syncookies_p)
    if tcp_syncookies is None:
        tcp_syncookies = 1  # Default kernel fallback

    tcp_max_syn_backlog = read_int_file(backlog_p)
    if tcp_max_syn_backlog is None:
        tcp_max_syn_backlog = 4096

    somaxconn = read_int_file(somaxconn_p)
    if somaxconn is None:
        somaxconn = 4096

    tcpext = parse_tcpext_netstat(netstat_p)

    syncookies_sent = tcpext.get("SyncookiesSent", 0)
    syncookies_recv = tcpext.get("SyncookiesRecv", 0)
    syncookies_failed = tcpext.get("SyncookiesFailed", 0)
    req_q_full_do_cookies = tcpext.get("TCPReqQFullDoCookies", 0)
    req_q_full_drop = tcpext.get("TCPReqQFullDrop", 0)
    fastopen_cookie_reqd = tcpext.get("TCPFastOpenCookieReqd", 0)
    listen_overflows = tcpext.get("ListenOverflows", 0)
    listen_drops = tcpext.get("ListenDrops", 0)

    issues: List[str] = []
    healthy = True

    if tcp_syncookies == 0:
        healthy = False
        issues.append("tcp_syncookies is disabled (0). Host vulnerable to SYN queue exhaustion and handshake drops.")
    elif tcp_syncookies == 2:
        healthy = False
        issues.append("tcp_syncookies is set to unconditional mode (2). Degrades TCP window scale and timestamps on all connections.")

    if tcp_max_syn_backlog < 1024:
        healthy = False
        issues.append(f"tcp_max_syn_backlog is low ({tcp_max_syn_backlog} < 1024). Multi-agent connection bursts may trigger premature SYN cookies.")

    if somaxconn < 1024:
        healthy = False
        issues.append(f"somaxconn is low ({somaxconn} < 1024). Listen backlog prone to overflow.")

    if req_q_full_drop > 0:
        healthy = False
        issues.append(f"TCP request queue full drops detected ({req_q_full_drop:,} dropped). Connection requests lost.")

    total_cookie_handshakes = syncookies_recv + syncookies_failed
    if syncookies_failed > 0 and total_cookie_handshakes > 50:
        fail_ratio = syncookies_failed / total_cookie_handshakes
        if fail_ratio > 0.10:
            healthy = False
            issues.append(f"Elevated SYN cookie validation failure rate ({fail_ratio:.1%} failed, {syncookies_failed:,} of {total_cookie_handshakes:,}).")

    if listen_drops > 0:
        healthy = False
        issues.append(f"TCP listen backlog drops detected ({listen_drops:,} drops). Application accept loop saturation.")

    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "tcp_syncookies": tcp_syncookies,
            "tcp_max_syn_backlog": tcp_max_syn_backlog,
            "somaxconn": somaxconn,
            "syncookies_sent": syncookies_sent,
            "syncookies_recv": syncookies_recv,
            "syncookies_failed": syncookies_failed,
            "req_q_full_do_cookies": req_q_full_do_cookies,
            "req_q_full_drop": req_q_full_drop,
            "listen_overflows": listen_overflows,
            "listen_drops": listen_drops,
            "issues": issues,
        },
        "counters": {
            "syncookies_sent": syncookies_sent,
            "syncookies_recv": syncookies_recv,
            "syncookies_failed": syncookies_failed,
            "req_q_full_do_cookies": req_q_full_do_cookies,
            "req_q_full_drop": req_q_full_drop,
            "fastopen_cookie_reqd": fastopen_cookie_reqd,
            "listen_overflows": listen_overflows,
            "listen_drops": listen_drops,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP SYN Cookie Guard (Pattern 118)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--syncookies-file", type=str, default=None, help="Path to tcp_syncookies")
    parser.add_argument("--backlog-file", type=str, default=None, help="Path to tcp_max_syn_backlog")
    parser.add_argument("--somaxconn-file", type=str, default=None, help="Path to somaxconn")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_syncookie(
        syncookies_file=args.syncookies_file,
        backlog_file=args.backlog_file,
        somaxconn_file=args.somaxconn_file,
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
    print(" Jev Multi-Agent Host Network TCP SYN Cookie Guard (Pattern 118)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" TCP SYN Cookies Sysctl:        {summary['tcp_syncookies']} ({'Enabled on Backlog Overflow' if summary['tcp_syncookies'] == 1 else 'Disabled' if summary['tcp_syncookies'] == 0 else 'Unconditional'})")
    print(f" Max SYN Backlog:               {summary['tcp_max_syn_backlog']:,}")
    print(f" Core Somaxconn:                {summary['somaxconn']:,}")
    print(f" SYN Cookies Sent:              {summary['syncookies_sent']:,}")
    print(f" SYN Cookies Validated:         {summary['syncookies_recv']:,}")
    print(f" SYN Cookies Failed:            {summary['syncookies_failed']:,}")
    print(f" Request Queue Full Cookies:    {summary['req_q_full_do_cookies']:,}")
    print(f" Request Queue Full Drops:      {summary['req_q_full_drop']:,}")
    print(f" Listen Drops:                  {summary['listen_drops']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'SYN Cookie / Queue Metric':<35} {'Count':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'SYN Cookies Sent':<35} {counters['syncookies_sent']:<15} Nominal")
    print(f" {'SYN Cookies Validated':<35} {counters['syncookies_recv']:<15} Nominal")
    print(f" {'SYN Cookies Failed':<35} {counters['syncookies_failed']:<15} {'Nominal' if counters['syncookies_failed'] == 0 else 'Investigate'}")
    print(f" {'Req Queue Full (Cookies Used)':<35} {counters['req_q_full_do_cookies']:<15} Nominal")
    print(f" {'Req Queue Full (Drops)':<35} {counters['req_q_full_drop']:<15} {'Nominal' if counters['req_q_full_drop'] == 0 else 'WARNING'}")
    print(f" {'Listen Overflows':<35} {counters['listen_overflows']:<15} {'Nominal' if counters['listen_overflows'] == 0 else 'WARNING'}")
    print(f" {'Listen Drops':<35} {counters['listen_drops']:<15} {'Nominal' if counters['listen_drops'] == 0 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive TCP SYN Cookie Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP SYN cookie and connection backlog parameters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
