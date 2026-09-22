#!/usr/bin/env python3
"""
fm-jev-synflood-guard.py - Jev Multi-Agent Host Network TCP SYN-Flood Drop & Request Queue Eviction Guard (Pattern 140)

Audits Linux TCP connection establishment defenses, listen queue overflows, and half-open
request queue (SYN backlog) health from sysctl parameters (/proc/sys/net/ipv4/tcp_syncookies,
/proc/sys/net/ipv4/tcp_max_syn_backlog, /proc/sys/net/core/somaxconn, /proc/sys/net/ipv4/tcp_synack_retries)
and /proc/net/netstat (TCPReqQFullDrop, TCPReqQFullDoCookies, ListenDrops, ListenOverflows,
SyncookiesSent, SyncookiesRecv, SyncookiesFailed, EmbryonicRsts).

In multi-agent architectures hosting multiple internal HTTP/WebSocket/gRPC servers (e.g.
Portal web server, Stack Monitor, Herdr daemon, local LLM endpoints), sudden bursts of
concurrent connection requests from multiple agents or automated test shards can saturate the
TCP listen accept queue or SYN request backlog. If SYN cookies are disabled or queues are
misconfigured, incoming connections are silently dropped, causing spurious connection timeouts
and failed health checks.

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

SYSCTL_SYNCOOKIES = "/proc/sys/net/ipv4/tcp_syncookies"
SYSCTL_SYN_BACKLOG = "/proc/sys/net/ipv4/tcp_max_syn_backlog"
SYSCTL_SOMAXCONN = "/proc/sys/net/core/somaxconn"
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


def parse_proc_pairs(path: Path, section_name: str) -> Dict[str, int]:
    """Parses paired header/metric lines from /proc/net/netstat."""
    if not path.is_file():
        return {}

    metrics: Dict[str, int] = {}
    try:
        lines = path.read_text().splitlines()
        for i in range(0, len(lines) - 1):
            line = lines[i]
            if line.startswith(f"{section_name}:"):
                keys = line.split()[1:]
                next_line = lines[i + 1]
                if next_line.startswith(f"{section_name}:"):
                    vals = next_line.split()[1:]
                    for k, v in zip(keys, vals):
                        try:
                            metrics[k] = int(v)
                        except ValueError:
                            continue
                break
    except Exception:
        pass
    return metrics


def audit_synflood_guard(
    syncookies_file: Optional[str] = None,
    syn_backlog_file: Optional[str] = None,
    somaxconn_file: Optional[str] = None,
    synack_retries_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits SYN flood protection, queue overflow, and listen drop metrics."""
    cookies_path = Path(syncookies_file or SYSCTL_SYNCOOKIES)
    backlog_path = Path(syn_backlog_file or SYSCTL_SYN_BACKLOG)
    somax_path = Path(somaxconn_file or SYSCTL_SOMAXCONN)
    retries_path = Path(synack_retries_file or SYSCTL_SYNACK_RETRIES)
    netstat_path = Path(netstat_file or PROC_NETSTAT)

    syncookies = read_int_file(cookies_path)
    if syncookies is None:
        syncookies = 1  # Safe fallback

    syn_backlog = read_int_file(backlog_path)
    if syn_backlog is None:
        syn_backlog = 4096

    somaxconn = read_int_file(somax_path)
    if somaxconn is None:
        somaxconn = 4096

    synack_retries = read_int_file(retries_path)
    if synack_retries is None:
        synack_retries = 5

    netstat_metrics = parse_proc_pairs(netstat_path, "TcpExt")

    req_q_full_drop = netstat_metrics.get("TCPReqQFullDrop", 0)
    req_q_full_cookies = netstat_metrics.get("TCPReqQFullDoCookies", 0)
    listen_drops = netstat_metrics.get("ListenDrops", 0)
    listen_overflows = netstat_metrics.get("ListenOverflows", 0)
    syncookies_sent = netstat_metrics.get("SyncookiesSent", 0)
    syncookies_recv = netstat_metrics.get("SyncookiesRecv", 0)
    syncookies_failed = netstat_metrics.get("SyncookiesFailed", 0)
    embryonic_rsts = netstat_metrics.get("EmbryonicRsts", 0)
    delivered = netstat_metrics.get("TCPDelivered", 0)

    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    # Evaluation Rules
    if syncookies == 0:
        status = "CRITICAL"
        issues.append("TCP SYN cookies are disabled (net.ipv4.tcp_syncookies=0)")
        recommendations.append("Enable SYN cookies immediately: sysctl -w net.ipv4.tcp_syncookies=1")

    if listen_overflows > 50 or req_q_full_drop > 50:
        status = "CRITICAL"
        issues.append(f"Severe listen queue drops detected: {listen_overflows:,} overflows, {req_q_full_drop:,} SYN drops")
        recommendations.append("Increase net.core.somaxconn and net.ipv4.tcp_max_syn_backlog to 8192 or 16384")
    elif listen_overflows > 0 or req_q_full_drop > 0 or listen_drops > 0:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Connection queue overflow events: {listen_overflows:,} listen overflows, {listen_drops:,} listen drops")
        recommendations.append("Inspect application accept() loop latency and consider increasing backlog queue size")

    if syn_backlog < 512 or somaxconn < 512:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"TCP backlog queue capacity is low: somaxconn={somaxconn}, syn_backlog={syn_backlog}")
        recommendations.append("Increase net.core.somaxconn and net.ipv4.tcp_max_syn_backlog to at least 4096")

    if syncookies_failed > 100:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Elevated SYN cookie validation failures: {syncookies_failed:,} failed cookies")
        recommendations.append("Check for potential SYN spoofing or network segment replay anomalies")

    if not recommendations:
        recommendations.append("TCP SYN flood defense, listen queue capacity, and backlog headroom operating nominally")

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_syncookies": syncookies,
            "tcp_max_syn_backlog": syn_backlog,
            "somaxconn": somaxconn,
            "tcp_synack_retries": synack_retries,
            "listen_drops": listen_drops,
            "listen_overflows": listen_overflows,
            "req_q_full_drop": req_q_full_drop,
            "req_q_full_cookies": req_q_full_cookies,
            "syncookies_sent": syncookies_sent,
            "syncookies_recv": syncookies_recv,
            "syncookies_failed": syncookies_failed,
            "embryonic_rsts": embryonic_rsts,
            "issues": issues,
            "recommendations": recommendations,
        },
        "counters": {
            "listen_drops": listen_drops,
            "listen_overflows": listen_overflows,
            "req_q_full_drop": req_q_full_drop,
            "req_q_full_cookies": req_q_full_cookies,
            "syncookies_sent": syncookies_sent,
            "syncookies_recv": syncookies_recv,
            "syncookies_failed": syncookies_failed,
            "embryonic_rsts": embryonic_rsts,
            "tcp_delivered": delivered,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP SYN-Flood Guard (Pattern 140)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--syncookies-file", type=str, help="Override path to tcp_syncookies sysctl")
    parser.add_argument("--syn-backlog-file", type=str, help="Override path to tcp_max_syn_backlog sysctl")
    parser.add_argument("--somaxconn-file", type=str, help="Override path to somaxconn sysctl")
    parser.add_argument("--synack-retries-file", type=str, help="Override path to tcp_synack_retries sysctl")
    parser.add_argument("--netstat-file", type=str, help="Override path to /proc/net/netstat")

    args = parser.parse_args()

    result = audit_synflood_guard(
        syncookies_file=args.syncookies_file,
        syn_backlog_file=args.syn_backlog_file,
        somaxconn_file=args.somaxconn_file,
        synack_retries_file=args.synack_retries_file,
        netstat_file=args.netstat_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    s = result["summary"]
    c = result["counters"]

    print("=== Jev Host Network TCP SYN-Flood Guard (Pattern 140) ===")
    print(f"Status:                    {s['status']}")
    print(f"TCP SYN Cookies:           {'Enabled (1)' if s['tcp_syncookies'] == 1 else ('Always (2)' if s['tcp_syncookies'] == 2 else 'Disabled (0)')}")
    print(f"Max SYN Backlog:           {s['tcp_max_syn_backlog']:,}")
    print(f"Socket Somaxconn Limit:    {s['somaxconn']:,}")
    print(f"SYN-ACK Retries:           {s['tcp_synack_retries']}")
    print(f"Listen Queue Drops:        {c['listen_drops']:,}")
    print(f"Listen Queue Overflows:    {c['listen_overflows']:,}")
    print(f"Request Queue Full Drops:  {c['req_q_full_drop']:,}")
    print(f"SYN Cookies Sent:          {c['syncookies_sent']:,}")
    print(f"SYN Cookies Validated:     {c['syncookies_recv']:,}")
    print(f"SYN Cookies Failed:        {c['syncookies_failed']:,}")
    print(f"Embryonic Resets:          {c['embryonic_rsts']:,}")

    if s["issues"]:
        print("\nIssues Identified:")
        for issue in s["issues"]:
            print(f"  - [!] {issue}")

    print("\nRecommendations:")
    for rec in s["recommendations"]:
        print(f"  - {rec}")


if __name__ == "__main__":
    main()
