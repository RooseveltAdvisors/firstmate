#!/usr/bin/env python3
"""
bin/fm-jev-timewait-guard.py - Host Network TCP TIME-WAIT Socket Recycling Guard (Pattern 164)

Audits active TIME-WAIT socket counts from /proc/net/sockstat against tcp_max_tw_buckets sysctl,
evaluates tcp_tw_reuse / tcp_tw_reuse_delay configuration, and tracks netstat counters (TW,
TWRecycled, TWKilled, TCPTimeWaitOverflow) to verify timestamp-safe socket recycling and eliminate
ephemeral connection establishment stalls across high-frequency agent RPC workloads.
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


def parse_sockstat(path: str = "/proc/net/sockstat") -> Dict[str, int]:
    info: Dict[str, int] = {}
    if not os.path.exists(path):
        return info
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if not parts:
                    continue
                if parts[0] == "TCP:":
                    for i in range(1, len(parts), 2):
                        if i + 1 < len(parts):
                            try:
                                info[parts[i]] = int(parts[i + 1])
                            except ValueError:
                                pass
    except Exception as e:
        print(f"Warning: unable to parse {path}: {e}", file=sys.stderr)
    return info


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
        print(f"Warning: unable to parse {path}: {e}", file=sys.stderr)
    return counters


def audit_timewait(
    sockstat_file: str = "/proc/net/sockstat",
    netstat_file: str = "/proc/net/netstat",
    max_tw_buckets_file: str = "/proc/sys/net/ipv4/tcp_max_tw_buckets",
    tw_reuse_file: str = "/proc/sys/net/ipv4/tcp_tw_reuse",
    tw_reuse_delay_file: str = "/proc/sys/net/ipv4/tcp_tw_reuse_delay",
) -> Dict[str, Any]:
    sockstat = parse_sockstat(sockstat_file)
    netstat = parse_netstat(netstat_file)
    max_tw_buckets = read_sysctl_int(max_tw_buckets_file)
    tw_reuse = read_sysctl_int(tw_reuse_file)
    tw_reuse_delay = read_sysctl_int(tw_reuse_delay_file)

    active_tw = sockstat.get("tw", 0)
    inuse = sockstat.get("inuse", 0)

    tw_total = netstat.get("TW", 0)
    tw_recycled = netstat.get("TWRecycled", 0)
    tw_killed = netstat.get("TWKilled", 0)
    paws_tw = netstat.get("PAWSTimewait", 0)
    tw_overflow = netstat.get("TCPTimeWaitOverflow", 0)

    bucket_utilization = (active_tw / max_tw_buckets) if max_tw_buckets > 0 else 0.0
    recycle_ratio = (tw_recycled / (tw_total + 1)) if tw_total > 0 else 0.0

    issues = []
    status = "HEALTHY"
    healthy = True

    if tw_overflow > 0:
        status = "WARNING"
        healthy = False
        issues.append(f"Detected TIME-WAIT table overflows (TCPTimeWaitOverflow={tw_overflow})")

    if bucket_utilization > 0.80:
        status = "WARNING"
        healthy = False
        issues.append(
            f"High TIME-WAIT table utilization: {active_tw}/{max_tw_buckets} ({bucket_utilization:.1%})"
        )

    summary = {
        "status": status,
        "healthy": healthy,
        "active_tw": active_tw,
        "tcp_inuse": inuse,
        "max_tw_buckets": max_tw_buckets,
        "bucket_utilization_pct": round(bucket_utilization * 100, 3),
        "tcp_tw_reuse": tw_reuse,
        "tcp_tw_reuse_delay_ms": tw_reuse_delay,
        "tw_total_historical": tw_total,
        "tw_recycled": tw_recycled,
        "tw_killed": tw_killed,
        "paws_tw": paws_tw,
        "tw_overflow": tw_overflow,
        "recycle_ratio_pct": round(recycle_ratio * 100, 3),
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sockstat": sockstat,
        "sysctls": {
            "tcp_max_tw_buckets": max_tw_buckets,
            "tcp_tw_reuse": tw_reuse,
            "tcp_tw_reuse_delay": tw_reuse_delay,
        },
        "counters": {
            "TW": tw_total,
            "TWRecycled": tw_recycled,
            "TWKilled": tw_killed,
            "PAWSTimewait": paws_tw,
            "TCPTimeWaitOverflow": tw_overflow,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP TIME-WAIT Socket Recycling Guard (Pattern 164)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_timewait()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP TIME-WAIT Guard (Pattern 164) - Status: {s['status']}")
    print(f"  Active TIME-WAIT Sockets:  {s['active_tw']:,} / {s['max_tw_buckets']:,} ({s['bucket_utilization_pct']}%)")
    print(f"  Active In-Use TCP Sockets: {s['tcp_inuse']:,}")
    print(f"  tcp_tw_reuse:              {s['tcp_tw_reuse']} (2 = timestamp-safe reuse active)")
    print(f"  tcp_tw_reuse_delay:        {s['tcp_tw_reuse_delay_ms']} ms")
    print(f"  Historical TW Recycled:    {s['tw_recycled']:,} / {s['tw_total_historical']:,} ({s['recycle_ratio_pct']}%)")
    print(f"  TIME-WAIT Overflows:       {s['tw_overflow']}")
    print(f"  PAWS Timewait Drops:       {s['paws_tw']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
