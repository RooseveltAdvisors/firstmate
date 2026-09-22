#!/usr/bin/env python3
"""
bin/fm-jev-fin-timeout-guard.py - Host Network TCP FIN Timeout & Orphan Connection Reclamation Guard (Pattern 193)

Audits kernel TCP socket closure timeout (tcp_fin_timeout), orphan socket limits (tcp_max_orphans),
orphan retry budgets (tcp_orphan_retries), live orphan socket counts from /proc/net/sockstat, and
netstat abort metrics (TCPAbortOnClose, TCPAbortOnTimeout, TCPAbortOnLinger, TCPAbortFailed,
TCPAbortOnData, TCPAbortOnMemory). Prevents socket descriptor leaks, TIME_WAIT/FIN_WAIT accumulation,
and orphan queue exhaustion under high-churn microservice RPC and streaming agent connections.
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List


def read_sysctl_int(path: str) -> int:
    if not os.path.exists(path):
        return -1
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception as e:
        print(f"Warning: unable to read {path}: {e}", file=sys.stderr)
        return -1


def parse_sockstat(path: str = "/proc/net/sockstat") -> Dict[str, int]:
    metrics: Dict[str, int] = {"inuse": 0, "orphan": 0, "tw": 0, "alloc": 0, "mem": 0}
    if not os.path.exists(path):
        return metrics
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("TCP:"):
                    parts = line.split()
                    for i in range(1, len(parts), 2):
                        if i + 1 < len(parts):
                            k = parts[i]
                            try:
                                metrics[k] = int(parts[i + 1])
                            except ValueError:
                                continue
    except Exception as e:
        print(f"Warning: unable to parse sockstat {path}: {e}", file=sys.stderr)
    return metrics


def parse_netstat_ext(path: str = "/proc/net/netstat") -> Dict[str, int]:
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
            if len(headers) == len(values) and headers[0] == "TcpExt:" and values[0] == "TcpExt:":
                for h, v in zip(headers[1:], values[1:]):
                    try:
                        counters[h] = int(v)
                    except ValueError:
                        continue
    except Exception as e:
        print(f"Warning: unable to parse netstat {path}: {e}", file=sys.stderr)
    return counters


def audit_fin_orphans(
    fin_timeout_file: str = "/proc/sys/net/ipv4/tcp_fin_timeout",
    max_orphans_file: str = "/proc/sys/net/ipv4/tcp_max_orphans",
    orphan_retries_file: str = "/proc/sys/net/ipv4/tcp_orphan_retries",
    sockstat_file: str = "/proc/net/sockstat",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    fin_timeout = read_sysctl_int(fin_timeout_file)
    max_orphans = read_sysctl_int(max_orphans_file)
    orphan_retries = read_sysctl_int(orphan_retries_file)

    sockstat = parse_sockstat(sockstat_file)
    netstat = parse_netstat_ext(netstat_file)

    orphan_count = sockstat.get("orphan", 0)
    inuse_tcp = sockstat.get("inuse", 0)
    tw_tcp = sockstat.get("tw", 0)

    orphan_sat_pct = round((orphan_count / max_orphans * 100.0), 4) if max_orphans > 0 else 0.0

    abort_on_close = netstat.get("TCPAbortOnClose", 0)
    abort_on_timeout = netstat.get("TCPAbortOnTimeout", 0)
    abort_on_linger = netstat.get("TCPAbortOnLinger", 0)
    abort_failed = netstat.get("TCPAbortFailed", 0)
    abort_on_data = netstat.get("TCPAbortOnData", 0)
    abort_on_memory = netstat.get("TCPAbortOnMemory", 0)

    issues: List[str] = []
    status = "HEALTHY"

    # Critical conditions
    if fin_timeout > 120:
        issues.append(f"tcp_fin_timeout ({fin_timeout}s) > 120s: excessive timeout leads to socket descriptor exhaustion")
        status = "CRITICAL"
    if orphan_sat_pct >= 80.0:
        issues.append(f"Orphan socket saturation ({orphan_sat_pct}%) exceeds 80.0% critical threshold: imminent socket allocation failure")
        status = "CRITICAL"
    if abort_on_memory > 100:
        issues.append(f"TCPAbortOnMemory ({abort_on_memory}) indicates severe kernel socket memory exhaustion")
        status = "CRITICAL"
    if max_orphans > 0 and max_orphans < 4096:
        issues.append(f"tcp_max_orphans ({max_orphans}) is dangerously small (< 4096)")
        status = "CRITICAL"

    # Warning conditions
    if status != "CRITICAL":
        if fin_timeout > 0 and fin_timeout < 15:
            issues.append(f"tcp_fin_timeout ({fin_timeout}s) < 15s: dangerously short timeout risks premature connection resets")
            status = "WARNING"
        if orphan_sat_pct >= 20.0:
            issues.append(f"Orphan socket saturation ({orphan_sat_pct}%) exceeds 20.0% warning threshold")
            status = "WARNING"
        if abort_failed > 500:
            issues.append(f"TCPAbortFailed ({abort_failed}) > 500: kernel failed to cleanly teardown aborted sockets")
            status = "WARNING"

    summary = {
        "status": status,
        "healthy": (status == "HEALTHY"),
        "tcp_fin_timeout_sec": fin_timeout,
        "tcp_max_orphans": max_orphans,
        "tcp_orphan_retries": orphan_retries,
        "active_orphans": orphan_count,
        "orphan_saturation_pct": orphan_sat_pct,
        "inuse_tcp_sockets": inuse_tcp,
        "timewait_tcp_sockets": tw_tcp,
        "abort_on_close": abort_on_close,
        "abort_on_timeout": abort_on_timeout,
        "abort_on_linger": abort_on_linger,
        "abort_failed": abort_failed,
        "abort_on_data": abort_on_data,
        "abort_on_memory": abort_on_memory,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_fin_timeout": fin_timeout,
            "tcp_max_orphans": max_orphans,
            "tcp_orphan_retries": orphan_retries,
        },
        "sockstat": {
            "orphan": orphan_count,
            "inuse": inuse_tcp,
            "tw": tw_tcp,
            "orphan_saturation_pct": orphan_sat_pct,
        },
        "netstat_counters": {
            "TCPAbortOnClose": abort_on_close,
            "TCPAbortOnTimeout": abort_on_timeout,
            "TCPAbortOnLinger": abort_on_linger,
            "TCPAbortFailed": abort_failed,
            "TCPAbortOnData": abort_on_data,
            "TCPAbortOnMemory": abort_on_memory,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP FIN Timeout & Orphan Connection Reclamation Guard (Pattern 193)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_fin_orphans()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP FIN Timeout & Orphan Guard (Pattern 193) - Status: {s['status']}")
    print(f"  tcp_fin_timeout:       {s['tcp_fin_timeout_sec']} seconds")
    print(f"  tcp_max_orphans:       {s['tcp_max_orphans']:,}")
    print(f"  Active Orphan Sockets: {s['active_orphans']} ({s['orphan_saturation_pct']}% saturation)")
    print(f"  In-Use TCP Sockets:    {s['inuse_tcp_sockets']:,}")
    print(f"  TIME_WAIT Sockets:     {s['timewait_tcp_sockets']:,}")
    print(f"  Aborts on Close:       {s['abort_on_close']:,}")
    print(f"  Aborts on Timeout:     {s['abort_on_timeout']:,}")
    print(f"  Aborts on Linger:      {s['abort_on_linger']:,}")
    print(f"  Aborts Failed:         {s['abort_failed']:,}")
    print(f"  Aborts on Data:        {s['abort_on_data']:,}")
    print(f"  Aborts on Memory:      {s['abort_on_memory']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
