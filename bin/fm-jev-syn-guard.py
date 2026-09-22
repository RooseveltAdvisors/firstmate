#!/usr/bin/env python3
"""
fm-jev-syn-guard.py - Jev Multi-Agent Host Network TCP Syncookie & SYN Flood Backlog Guard (Pattern 96)

Audits Linux host TCP SYN backlog parameters, syncookie configuration, and listen queue overflow/drop counters
from /proc/sys/net/ipv4/tcp_syncookies, /proc/sys/net/ipv4/tcp_max_syn_backlog, /proc/sys/net/core/somaxconn,
and /proc/net/netstat (TcpExt).

Detects socket backlog starvation, listen drops, and unhandled connection queue overflows during intense
multi-agent RPC burst traffic.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysfs or /proc files are missing or restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

PROC_NETSTAT = "/proc/net/netstat"
SYSCTL_TCP_SYNCOOKIES = "/proc/sys/net/ipv4/tcp_syncookies"
SYSCTL_MAX_SYN_BACKLOG = "/proc/sys/net/ipv4/tcp_max_syn_backlog"
SYSCTL_SOMAXCONN = "/proc/sys/net/core/somaxconn"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def parse_tcpext_netstat(netstat_path: Path) -> Dict[str, int]:
    """Parses TcpExt key-value metrics from /proc/net/netstat."""
    if not netstat_path.is_file():
        return {}

    metrics: Dict[str, int] = {}
    try:
        lines = netstat_path.read_text().splitlines()
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
        return {}

    return metrics


def audit_syn_backlog(
    netstat_file: Optional[str] = None,
    syncookies_file: Optional[str] = None,
    syn_backlog_file: Optional[str] = None,
    somaxconn_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TCP SYN backlog, syncookies status, and listen drop counters."""
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)
    syncookies_path = Path(syncookies_file) if syncookies_file else Path(SYSCTL_TCP_SYNCOOKIES)
    syn_backlog_path = Path(syn_backlog_file) if syn_backlog_file else Path(SYSCTL_MAX_SYN_BACKLOG)
    somaxconn_path = Path(somaxconn_file) if somaxconn_file else Path(SYSCTL_SOMAXCONN)

    tcp_syncookies = read_int_file(syncookies_path)
    tcp_max_syn_backlog = read_int_file(syn_backlog_path)
    somaxconn = read_int_file(somaxconn_path)

    tcpext = parse_tcpext_netstat(netstat_path)

    # Key counters
    syncookies_sent = tcpext.get("SyncookiesSent", 0)
    syncookies_recv = tcpext.get("SyncookiesRecv", 0)
    syncookies_failed = tcpext.get("SyncookiesFailed", 0)
    embryonic_rsts = tcpext.get("EmbryonicRsts", 0)
    listen_overflows = tcpext.get("ListenOverflows", 0)
    listen_drops = tcpext.get("ListenDrops", 0)
    tcp_backlog_drop = tcpext.get("TCPBacklogDrop", 0)
    req_q_full_cookies = tcpext.get("TCPReqQFullDoCookies", 0)
    req_q_full_drop = tcpext.get("TCPReqQFullDrop", 0)

    issues: List[str] = []

    # Config checks
    if tcp_syncookies is not None and tcp_syncookies == 0:
        issues.append("TCP syncookies disabled (tcp_syncookies=0): vulnerable to SYN flood queue exhaustion")

    if tcp_max_syn_backlog is not None and tcp_max_syn_backlog < 512:
        issues.append(f"Low tcp_max_syn_backlog ({tcp_max_syn_backlog} < 512): risk of SYN starvation during burst traffic")

    if somaxconn is not None and somaxconn < 512:
        issues.append(f"Low somaxconn ({somaxconn} < 512): risk of socket listen queue saturation")

    # Runtime counter checks
    if listen_overflows > 0:
        issues.append(f"Socket listen queue overflows detected ({listen_overflows}): application listen queues saturated")

    if listen_drops > 0:
        issues.append(f"TCP listen drops detected ({listen_drops}): incoming connections dropped at listen backlog")

    if tcp_backlog_drop > 0:
        issues.append(f"TCP backlog drops detected ({tcp_backlog_drop}): packets dropped due to full socket backlog")

    if req_q_full_drop > 0:
        issues.append(f"TCP request queue full drops detected ({req_q_full_drop}): connection requests dropped")

    if syncookies_failed > 0:
        issues.append(f"TCP syncookies validation failed ({syncookies_failed}): potential SYN flood or corrupted handshake")

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_syncookies": tcp_syncookies,
            "tcp_max_syn_backlog": tcp_max_syn_backlog,
            "somaxconn": somaxconn,
            "issues": issues,
        },
        "counters": {
            "syncookies_sent": syncookies_sent,
            "syncookies_recv": syncookies_recv,
            "syncookies_failed": syncookies_failed,
            "embryonic_rsts": embryonic_rsts,
            "listen_overflows": listen_overflows,
            "listen_drops": listen_drops,
            "tcp_backlog_drop": tcp_backlog_drop,
            "tcp_req_q_full_do_cookies": req_q_full_cookies,
            "tcp_req_q_full_drop": req_q_full_drop,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Syncookie & SYN Flood Backlog Guard (Pattern 96)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    parser.add_argument("--syncookies-file", type=str, default=None, help="Path to tcp_syncookies")
    parser.add_argument("--syn-backlog-file", type=str, default=None, help="Path to tcp_max_syn_backlog")
    parser.add_argument("--somaxconn-file", type=str, default=None, help="Path to somaxconn")
    args = parser.parse_args()

    result = audit_syn_backlog(
        netstat_file=args.netstat_file,
        syncookies_file=args.syncookies_file,
        syn_backlog_file=args.syn_backlog_file,
        somaxconn_file=args.somaxconn_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    cookies_label = {0: "Disabled (0)", 1: "Enabled on Queue Full (1)", 2: "Always (2)"}.get(
        summary["tcp_syncookies"], str(summary["tcp_syncookies"])
    )

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP Syncookie & SYN Flood Backlog Guard (Pattern 96)")
    print("================================================================================")
    print(f" Timestamp:                 {result['timestamp']}")
    print(f" Status:                    {status_color}{summary['status']}{reset_color}")
    print(f" TCP Syncookies:            {cookies_label}")
    print(f" Max SYN Backlog:           {summary['tcp_max_syn_backlog']}")
    print(f" Core SOMAXCONN:            {summary['somaxconn']}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Metric':<30} {'Count':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Listen Overflows':<30} {counters['listen_overflows']:<15} {'Nominal' if counters['listen_overflows'] == 0 else 'WARNING'}")
    print(f" {'Listen Drops':<30} {counters['listen_drops']:<15} {'Nominal' if counters['listen_drops'] == 0 else 'WARNING'}")
    print(f" {'TCP Backlog Drops':<30} {counters['tcp_backlog_drop']:<15} {'Nominal' if counters['tcp_backlog_drop'] == 0 else 'WARNING'}")
    print(f" {'Req Q Full Drops':<30} {counters['tcp_req_q_full_drop']:<15} {'Nominal' if counters['tcp_req_q_full_drop'] == 0 else 'WARNING'}")
    print(f" {'Syncookies Sent':<30} {counters['syncookies_sent']:<15} {'Active' if counters['syncookies_sent'] > 0 else 'Zero'}")
    print(f" {'Syncookies Received':<30} {counters['syncookies_recv']:<15} {'Active' if counters['syncookies_recv'] > 0 else 'Zero'}")
    print(f" {'Syncookies Failed':<30} {counters['syncookies_failed']:<15} {'Nominal' if counters['syncookies_failed'] == 0 else 'WARNING'}")
    print(f" {'Embryonic Resets':<30} {counters['embryonic_rsts']:<15} {'Nominal'}")

    if summary["issues"]:
        print("\nActive TCP SYN / Listen Backlog Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll TCP SYN backlog, syncookies, and socket listen parameters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
