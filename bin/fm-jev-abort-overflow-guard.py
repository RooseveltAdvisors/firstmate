#!/usr/bin/env python3
"""
bin/fm-jev-abort-overflow-guard.py - Host Network TCP Listener Abort-On-Overflow & SYN Drop Recovery Guard (Pattern 187)

Audits kernel TCP listener abort-on-overflow behavior (tcp_abort_on_overflow), FIN-WAIT-2 timeout (tcp_fin_timeout),
SYN backlog limits (tcp_max_syn_backlog), and socket listener queue ceiling (somaxconn) alongside listen overflows,
drops, and request queue drops in /proc/net/netstat. Verifies fail-safe exponential backoff on listener backlog
saturation rather than active RST destruction, preventing cascading client reconnect storms across multi-agent microservices.
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict


def read_sysctl_int(path: str) -> int:
    if not os.path.exists(path):
        return -1
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception as e:
        print(f"Warning: unable to read {path}: {e}", file=sys.stderr)
        return -1


def parse_netstat(path: str = "/proc/net/netstat") -> Dict[str, int]:
    counters: Dict[str, int] = {}
    if not os.path.exists(path):
        return counters
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
        for i in range(0, len(lines), 2):
            if i + 1 >= len(lines):
                break
            headers = lines[i].split()
            values = lines[i + 1].split()
            if len(headers) == len(values) and headers[0] == values[0]:
                for h, v in zip(headers[1:], values[1:]):
                    try:
                        counters[h] = int(v)
                    except ValueError:
                        pass
    except Exception as e:
        print(f"Warning: unable to parse netstat {path}: {e}", file=sys.stderr)
    return counters


def audit_abort_overflow(
    abort_overflow_file: str = "/proc/sys/net/ipv4/tcp_abort_on_overflow",
    fin_timeout_file: str = "/proc/sys/net/ipv4/tcp_fin_timeout",
    syn_backlog_file: str = "/proc/sys/net/ipv4/tcp_max_syn_backlog",
    somaxconn_file: str = "/proc/sys/net/core/somaxconn",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    abort_on_overflow = read_sysctl_int(abort_overflow_file)
    fin_timeout = read_sysctl_int(fin_timeout_file)
    max_syn_backlog = read_sysctl_int(syn_backlog_file)
    somaxconn = read_sysctl_int(somaxconn_file)

    netstat = parse_netstat(netstat_file)

    listen_overflows = netstat.get("ListenOverflows", 0)
    listen_drops = netstat.get("ListenDrops", 0)
    req_q_full_drop = netstat.get("TCPReqQFullDrop", 0)
    req_q_full_cookies = netstat.get("TCPReqQFullDoCookies", 0)
    embryonic_rsts = netstat.get("EmbryonicRsts", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    if abort_on_overflow == -1:
        status = "WARNING"
        healthy = False
        issues.append("Unable to read net.ipv4.tcp_abort_on_overflow sysctl")
    elif abort_on_overflow == 1:
        status = "WARNING"
        healthy = False
        issues.append(
            "tcp_abort_on_overflow is set to 1 (RST sent on full backlog, breaks client exponential backoff/reconnect)"
        )

    if fin_timeout == -1:
        status = "WARNING"
        healthy = False
        issues.append("Unable to read net.ipv4.tcp_fin_timeout sysctl")
    elif fin_timeout > 120:
        status = "WARNING"
        healthy = False
        issues.append(f"Excessive TCP FIN timeout: {fin_timeout}s (> 120s leads to orphaned socket accumulation)")
    elif fin_timeout < 10:
        status = "WARNING"
        healthy = False
        issues.append(f"Sub-optimal TCP FIN timeout: {fin_timeout}s (< 10s risks premature teardown)")

    if max_syn_backlog < 512 and max_syn_backlog != -1:
        status = "WARNING"
        healthy = False
        issues.append(f"Small SYN backlog queue: {max_syn_backlog} (< 512)")

    if somaxconn < 512 and somaxconn != -1:
        status = "WARNING"
        healthy = False
        issues.append(f"Small somaxconn socket queue: {somaxconn} (< 512)")

    if listen_overflows > 100:
        status = "WARNING"
        healthy = False
        issues.append(f"High listener queue overflows detected: {listen_overflows}")

    if listen_drops > 100:
        status = "WARNING"
        healthy = False
        issues.append(f"High listener drops detected: {listen_drops}")

    if req_q_full_drop > 0:
        status = "WARNING"
        healthy = False
        issues.append(f"TCP request queue full drops detected: {req_q_full_drop}")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_abort_on_overflow": abort_on_overflow,
        "tcp_fin_timeout": fin_timeout,
        "tcp_max_syn_backlog": max_syn_backlog,
        "somaxconn": somaxconn,
        "listen_overflows": listen_overflows,
        "listen_drops": listen_drops,
        "req_q_full_drop": req_q_full_drop,
        "req_q_full_cookies": req_q_full_cookies,
        "embryonic_rsts": embryonic_rsts,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_abort_on_overflow": abort_on_overflow,
            "tcp_fin_timeout": fin_timeout,
            "tcp_max_syn_backlog": max_syn_backlog,
            "somaxconn": somaxconn,
        },
        "counters": {
            "ListenOverflows": listen_overflows,
            "ListenDrops": listen_drops,
            "TCPReqQFullDrop": req_q_full_drop,
            "TCPReqQFullDoCookies": req_q_full_cookies,
            "EmbryonicRsts": embryonic_rsts,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Listener Abort-On-Overflow & SYN Drop Recovery Guard (Pattern 187)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_abort_overflow()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Listener Abort-On-Overflow Guard (Pattern 187) - Status: {s['status']}")
    print(f"  tcp_abort_on_overflow:  {s['tcp_abort_on_overflow']} (0 = drop SYN & allow retry)")
    print(f"  tcp_fin_timeout:        {s['tcp_fin_timeout']} seconds")
    print(f"  tcp_max_syn_backlog:    {s['tcp_max_syn_backlog']} entries")
    print(f"  somaxconn:              {s['somaxconn']} entries")
    print(f"  Listen Drops/Overflows: {s['listen_drops']} / {s['listen_overflows']}")
    print(f"  Req Queue Full Drops:   {s['req_q_full_drop']}")
    print(f"  Embryonic Resets:       {s['embryonic_rsts']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
