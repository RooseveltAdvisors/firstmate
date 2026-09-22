#!/usr/bin/env python3
"""
fm-jev-syn-cookie-watermark-guard.py - Jev Multi-Agent Host Network TCP SYN-Cookie High Watermark & Hash Exhaustion Guard (Pattern 145)

Audits Linux TCP SYN-cookie fallback mechanisms, backlog watermarks, and hash validation metrics:
  - /proc/sys/net/ipv4/tcp_syncookies (0=disabled, 1=on backlog overflow, 2=unconditional)
  - /proc/sys/net/ipv4/tcp_max_syn_backlog (half-open connection backlog capacity)
  - /proc/sys/net/core/somaxconn (listen accept queue capacity)
  - /proc/net/netstat metrics:
      - SyncookiesSent (SYN cookies generated under queue pressure)
      - SyncookiesRecv (Valid SYN cookies acknowledged and accepted)
      - SyncookiesFailed (Invalid / corrupted SYN cookie acknowledgments)
      - ListenOverflows (Listen queue overflows)
      - ListenDrops (Connections dropped due to listen or backlog saturation)
      - TCPSynRetrans (SYN/ACK retransmissions)

In high-concurrency multi-agent mesh clusters, unexpected SYN-cookie generation indicates
per-socket SYN backlog exhaustion or connection micro-bursts, which can degrade TCP performance
by stripping TCP options (e.g. SACK, WScale) when timestamp extension is unavailable.

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
SYSCTL_SYNCOOKIES = "/proc/sys/net/ipv4/tcp_syncookies"
SYSCTL_SYN_BACKLOG = "/proc/sys/net/ipv4/tcp_max_syn_backlog"
SYSCTL_SOMAXCONN = "/proc/sys/net/core/somaxconn"


def read_int_from_file(path: Path, default: int = 0) -> int:
    """Reads an integer safely from a sysctl file."""
    if not path.is_file():
        return default
    try:
        return int(path.read_text().strip())
    except Exception:
        return default


def parse_netstat_syncookie_counters(netstat_path: Path) -> Dict[str, int]:
    """Parses SYN-cookie and listen queue metrics from /proc/net/netstat."""
    counters: Dict[str, int] = {
        "syncookies_sent": 0,
        "syncookies_recv": 0,
        "syncookies_failed": 0,
        "listen_overflows": 0,
        "listen_drops": 0,
        "syn_retrans": 0,
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

                counters["syncookies_sent"] = header_map.get("SyncookiesSent", 0)
                counters["syncookies_recv"] = header_map.get("SyncookiesRecv", 0)
                counters["syncookies_failed"] = header_map.get("SyncookiesFailed", 0)
                counters["listen_overflows"] = header_map.get("ListenOverflows", 0)
                counters["listen_drops"] = header_map.get("ListenDrops", 0)
                counters["syn_retrans"] = header_map.get("TCPSynRetrans", 0)
                break
    except Exception:
        pass

    return counters


def audit_syncookie_watermark(
    netstat_file: Optional[str] = None,
    syncookies_file: Optional[str] = None,
    backlog_file: Optional[str] = None,
    somaxconn_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Performs an audit of TCP SYN-cookie configuration and queue metrics."""
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)
    syncookies_path = Path(syncookies_file) if syncookies_file else Path(SYSCTL_SYNCOOKIES)
    backlog_path = Path(backlog_file) if backlog_file else Path(SYSCTL_SYN_BACKLOG)
    somaxconn_path = Path(somaxconn_file) if somaxconn_file else Path(SYSCTL_SOMAXCONN)

    tcp_syncookies = read_int_from_file(syncookies_path, default=1)
    tcp_max_syn_backlog = read_int_from_file(backlog_path, default=4096)
    somaxconn = read_int_from_file(somaxconn_path, default=4096)

    counters = parse_netstat_syncookie_counters(netstat_path)
    cookies_sent = counters["syncookies_sent"]
    cookies_recv = counters["syncookies_recv"]
    cookies_failed = counters["syncookies_failed"]
    listen_overflows = counters["listen_overflows"]
    listen_drops = counters["listen_drops"]

    # Calculate completion ratio and failure ratio
    completion_ratio_pct = round((cookies_recv / cookies_sent * 100), 2) if cookies_sent > 0 else 100.0
    failed_ratio_pct = round((cookies_failed / cookies_recv * 100), 2) if cookies_recv > 0 else 0.0

    issues: List[str] = []

    # 1. Syncookies disabled
    if tcp_syncookies == 0:
        issues.append("tcp_syncookies is disabled (0); vulnerable to SYN-flood queue exhaustion")
    elif tcp_syncookies == 2:
        issues.append("tcp_syncookies is forced unconditionally (2); reduces TCP option negotiation efficiency")

    # 2. Backlog under-provisioning (< 1024)
    if tcp_max_syn_backlog < 1024:
        issues.append(f"tcp_max_syn_backlog is under-provisioned ({tcp_max_syn_backlog} < 1024)")

    # 3. High failure ratio (> 20%)
    if cookies_recv >= 50 and failed_ratio_pct > 20.0:
        issues.append(
            f"Elevated SYN-cookie verification failure ratio ({failed_ratio_pct}%: {cookies_failed:,} failed / {cookies_recv:,} recv)"
        )

    # 4. Listen queue drops
    if listen_drops > 1000:
        issues.append(f"High listen queue drops detected ({listen_drops:,} drops)")

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "tcp_syncookies": tcp_syncookies,
            "tcp_max_syn_backlog": tcp_max_syn_backlog,
            "somaxconn": somaxconn,
            "cookies_sent": cookies_sent,
            "cookies_recv": cookies_recv,
            "cookies_failed": cookies_failed,
            "completion_ratio_pct": completion_ratio_pct,
            "failed_ratio_pct": failed_ratio_pct,
            "listen_overflows": listen_overflows,
            "listen_drops": listen_drops,
            "issues": issues,
        },
        "counters": counters,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP SYN-Cookie High Watermark & Hash Exhaustion Guard (Pattern 145)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    parser.add_argument("--sysctl-syncookies", type=str, default=None, help="Path to tcp_syncookies")
    parser.add_argument("--sysctl-backlog", type=str, default=None, help="Path to tcp_max_syn_backlog")
    parser.add_argument("--sysctl-somaxconn", type=str, default=None, help="Path to somaxconn")
    args = parser.parse_args()

    result = audit_syncookie_watermark(
        netstat_file=args.netstat_file,
        syncookies_file=args.sysctl_syncookies,
        backlog_file=args.sysctl_backlog,
        somaxconn_file=args.sysctl_somaxconn,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP SYN-Cookie High Watermark Guard (Pattern 145)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" tcp_syncookies Mode:           {summary['tcp_syncookies']} (1 = on backlog overflow)")
    print(f" tcp_max_syn_backlog:           {summary['tcp_max_syn_backlog']:,} half-open slots")
    print(f" somaxconn (Accept Queue):      {summary['somaxconn']:,} sockets")
    print(f" SYN Cookies Sent:              {summary['cookies_sent']:,}")
    print(f" SYN Cookies Received:          {summary['cookies_recv']:,} ({summary['completion_ratio_pct']}% completion)")
    print(f" SYN Cookies Failed:            {summary['cookies_failed']:,} ({summary['failed_ratio_pct']}% failure ratio)")
    print(f" Listen Queue Overflows:        {summary['listen_overflows']:,}")
    print(f" Listen Queue Drops:            {summary['listen_drops']:,}")
    print(f" SYN Retransmissions:           {counters['syn_retrans']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'SYN-Cookie / Backlog Metric':<35} {'Count / Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'SYN Cookie Activation Mode':<35} {summary['tcp_syncookies']:<15} {'Nominal' if summary['tcp_syncookies'] == 1 else 'WARNING'}")
    print(f" {'SYN Backlog Capacity':<35} {summary['tcp_max_syn_backlog']:<15} {'Nominal' if summary['tcp_max_syn_backlog'] >= 1024 else 'WARNING'}")
    print(f" {'SYN Cookie Verification':<35} {summary['cookies_failed']:<15} {'Nominal' if summary['failed_ratio_pct'] <= 20.0 else 'WARNING'}")
    print(f" {'Listen Drops':<35} {summary['listen_drops']:<15} {'Nominal' if summary['listen_drops'] <= 1000 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive TCP SYN-Cookie / Backlog Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP SYN-cookie fallback mechanisms, backlog watermarks, and verification nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
