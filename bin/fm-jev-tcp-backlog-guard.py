#!/usr/bin/env python3
"""
fm-jev-tcp-backlog-guard.py - Jev Multi-Agent Network Socket Backlog & SYN Queue Overflow Guard (Pattern 78)

Audits Linux kernel TCP listen queue backlog, SYN backlog saturation, aggregate kernel drop counters
(/proc/net/netstat TcpExt: ListenOverflows, ListenDrops, TCPBacklogDrop, TCPReqQFullDrop), and sysctl
limits (somaxconn, tcp_max_syn_backlog) to prevent connection timeouts, 502/504 Bad Gateways, and
microservice request dropping under concurrent multi-agent workloads.

Invariants:
  - Read-only diagnostics. Non-destructive.
  - Fail-open: graceful fallback on systems without ss or non-standard procfs.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_WARN_SOCKET_SAT_PCT = 70.0
DEFAULT_CRIT_SOCKET_SAT_PCT = 90.0
MIN_RECOMMENDED_SOMAXCONN = 128
MIN_RECOMMENDED_SYN_BACKLOG = 128

PROC_NETSTAT = "/proc/net/netstat"
SYS_SOMAXCONN = "/proc/sys/net/core/somaxconn"
SYS_SYN_BACKLOG = "/proc/sys/net/ipv4/tcp_max_syn_backlog"
SYS_SYNCOOKIES = "/proc/sys/net/ipv4/tcp_syncookies"


def read_sysctl_int(path: str, default: int = 0) -> int:
    """Reads integer sysctl."""
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r") as f:
            return int(f.read().strip())
    except Exception:
        return default


def parse_netstat_tcpext(path: str = PROC_NETSTAT) -> Dict[str, int]:
    """Parses /proc/net/netstat TcpExt header and values into a dictionary."""
    counters: Dict[str, int] = {}
    if not os.path.exists(path):
        return counters
    try:
        with open(path, "r") as f:
            lines = f.readlines()
            for i in range(0, len(lines) - 1, 2):
                hdr = lines[i].split()
                val = lines[i + 1].split()
                if hdr and hdr[0] == "TcpExt:" and len(hdr) == len(val):
                    for k, v in zip(hdr[1:], val[1:]):
                        try:
                            counters[k] = int(v)
                        except ValueError:
                            pass
    except Exception:
        pass
    return counters


def parse_listen_sockets(ss_bin: Optional[str] = None) -> List[Dict[str, Any]]:
    """Gathers listening TCP sockets using ss -lntH if available."""
    sockets: List[Dict[str, Any]] = []
    if ss_bin is None:
        ss_bin = shutil.which("ss")
    if not ss_bin or not os.path.exists(ss_bin):
        return sockets

    try:
        proc = subprocess.run(
            [ss_bin, "-lntH"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=1.0,
            check=False,
        )
        if proc.returncode != 0:
            return sockets

        for line in proc.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) >= 4 and parts[0] == "LISTEN":
                try:
                    recv_q = int(parts[1])
                    send_q = int(parts[2])
                    local_addr = parts[3]
                    sat_pct = round((recv_q / send_q * 100.0), 2) if send_q > 0 else 0.0
                    sockets.append({
                        "local_address": local_addr,
                        "recv_q": recv_q,
                        "send_q": send_q,
                        "saturation_pct": sat_pct,
                    })
                except ValueError:
                    pass
    except Exception:
        pass

    return sockets


def audit_tcp_backlog(
    netstat_path: str = PROC_NETSTAT,
    somaxconn_path: str = SYS_SOMAXCONN,
    syn_backlog_path: str = SYS_SYN_BACKLOG,
    syncookies_path: str = SYS_SYNCOOKIES,
    mock_sockets: Optional[List[Dict[str, Any]]] = None,
    warn_sat_pct: float = DEFAULT_WARN_SOCKET_SAT_PCT,
    crit_sat_pct: float = DEFAULT_CRIT_SOCKET_SAT_PCT,
) -> Dict[str, Any]:
    """Audits kernel TCP backlog counters, sysctl limits, and active socket queues."""
    tcpext = parse_netstat_tcpext(netstat_path)
    somaxconn = read_sysctl_int(somaxconn_path, default=4096)
    syn_backlog = read_sysctl_int(syn_backlog_path, default=4096)
    syncookies = read_sysctl_int(syncookies_path, default=1)

    listen_overflows = tcpext.get("ListenOverflows", 0)
    listen_drops = tcpext.get("ListenDrops", 0)
    backlog_drops = tcpext.get("TCPBacklogDrop", 0)
    req_q_full_cookies = tcpext.get("TCPReqQFullDoCookies", 0)
    req_q_full_drops = tcpext.get("TCPReqQFullDrop", 0)
    tw_overflows = tcpext.get("TCPTimeWaitOverflow", 0)

    sockets = mock_sockets if mock_sockets is not None else parse_listen_sockets()

    saturated_sockets: List[Dict[str, Any]] = []
    max_socket_sat_pct = 0.0
    for s in sockets:
        sat = s.get("saturation_pct", 0.0)
        if sat > max_socket_sat_pct:
            max_socket_sat_pct = sat
        if sat >= warn_sat_pct:
            saturated_sockets.append(s)

    issues: List[str] = []
    status = "HEALTHY"

    # Evaluate socket queue saturation
    if any(s.get("saturation_pct", 0.0) >= crit_sat_pct for s in sockets):
        status = "CRITICAL"
        crit_socks = [f"{s['local_address']} ({s['recv_q']}/{s['send_q']} = {s['saturation_pct']}%)" for s in sockets if s.get("saturation_pct", 0.0) >= crit_sat_pct]
        issues.append(f"Critical listen socket backlog saturation: {', '.join(crit_socks)}")
    elif saturated_sockets:
        status = "WARNING"
        warn_socks = [f"{s['local_address']} ({s['recv_q']}/{s['send_q']} = {s['saturation_pct']}%)" for s in saturated_sockets]
        issues.append(f"Elevated listen socket backlog saturation: {', '.join(warn_socks)}")

    # Evaluate kernel drop counters
    if listen_drops > 0 or req_q_full_drops > 0 or backlog_drops > 0:
        # If not already critical, elevate
        if status != "CRITICAL" and (listen_drops > 100 or req_q_full_drops > 100):
            status = "CRITICAL"
        elif status == "HEALTHY":
            status = "WARNING"
        issues.append(f"Kernel TCP listen drops detected: ListenDrops={listen_drops}, ReqQFullDrop={req_q_full_drops}, BacklogDrop={backlog_drops}")

    if listen_overflows > 0 and not any("ListenDrops" in iss for iss in issues):
        if status == "HEALTHY":
            status = "WARNING"
        issues.append(f"Kernel TCP listen overflows detected: ListenOverflows={listen_overflows}")

    # Evaluate sysctl limits
    if somaxconn < MIN_RECOMMENDED_SOMAXCONN:
        if status == "HEALTHY":
            status = "WARNING"
        issues.append(f"Low net.core.somaxconn ({somaxconn} < {MIN_RECOMMENDED_SOMAXCONN})")

    if syn_backlog < MIN_RECOMMENDED_SYN_BACKLOG:
        if status == "HEALTHY":
            status = "WARNING"
        issues.append(f"Low tcp_max_syn_backlog ({syn_backlog} < {MIN_RECOMMENDED_SYN_BACKLOG})")

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "total_listen_sockets": len(sockets),
            "saturated_sockets_count": len(saturated_sockets),
            "max_socket_saturation_pct": max_socket_sat_pct,
            "listen_overflows": listen_overflows,
            "listen_drops": listen_drops,
            "backlog_drops": backlog_drops,
            "req_q_full_drops": req_q_full_drops,
            "req_q_full_cookies": req_q_full_cookies,
            "tw_overflows": tw_overflows,
            "issues": issues,
        },
        "sysctl": {
            "somaxconn": somaxconn,
            "tcp_max_syn_backlog": syn_backlog,
            "tcp_syncookies": syncookies,
        },
        "saturated_sockets": saturated_sockets,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Network Socket Backlog & SYN Queue Overflow Guard (Pattern 78)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--warn-sat", type=float, default=DEFAULT_WARN_SOCKET_SAT_PCT, help=f"Warning socket saturation pct (default {DEFAULT_WARN_SOCKET_SAT_PCT})")
    parser.add_argument("--crit-sat", type=float, default=DEFAULT_CRIT_SOCKET_SAT_PCT, help=f"Critical socket saturation pct (default {DEFAULT_CRIT_SOCKET_SAT_PCT})")
    parser.add_argument("--proc-netstat", type=str, default=PROC_NETSTAT, help="Path to /proc/net/netstat")
    parser.add_argument("--sysctl-somaxconn", type=str, default=SYS_SOMAXCONN, help="Path to somaxconn sysctl")
    parser.add_argument("--sysctl-syn-backlog", type=str, default=SYS_SYN_BACKLOG, help="Path to tcp_max_syn_backlog sysctl")

    args = parser.parse_args()

    result = audit_tcp_backlog(
        netstat_path=args.proc_netstat,
        somaxconn_path=args.sysctl_somaxconn,
        syn_backlog_path=args.sysctl_syn_backlog,
        warn_sat_pct=args.warn_sat,
        crit_sat_pct=args.crit_sat,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else ("\033[31m" if summary["status"] == "CRITICAL" else "\033[33m")
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent TCP Backlog & SYN Queue Guard (Pattern 78)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    print(f" Listen Sockets:         {summary['total_listen_sockets']} active ({summary['saturated_sockets_count']} saturated)")
    print(f" Max Queue Saturation:   {summary['max_socket_saturation_pct']}%")
    print(f" Listen Overflows/Drops: {summary['listen_overflows']} overflows, {summary['listen_drops']} drops")
    print(f" Backlog / ReqQ Drops:   {summary['backlog_drops']} backlog drops, {summary['req_q_full_drops']} syn-drops")
    print(f" Kernel Limits:          somaxconn={result['sysctl']['somaxconn']}, syn_backlog={result['sysctl']['tcp_max_syn_backlog']}, syncookies={result['sysctl']['tcp_syncookies']}")

    if summary["issues"]:
        print("\nActive Issues:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nNo TCP backlog congestion, queue overflows, or SYN drop pressure detected.")
    print("================================================================================")


if __name__ == "__main__":
    main()
