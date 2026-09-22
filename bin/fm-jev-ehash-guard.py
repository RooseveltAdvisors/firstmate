#!/usr/bin/env python3
"""
bin/fm-jev-ehash-guard.py - Host Network TCP Established Socket Hash Table Guard (Pattern 166)

Audits kernel established socket 4-tuple hash table capacity (tcp_ehash_entries) against
active TCP socket counts from /proc/net/sockstat to verify O(1) connection lookup performance
and eliminate hash chain traversal CPU contention across high-concurrency multi-agent workloads.
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


def audit_ehash(
    sockstat_file: str = "/proc/net/sockstat",
    ehash_entries_file: str = "/proc/sys/net/ipv4/tcp_ehash_entries",
    child_ehash_file: str = "/proc/sys/net/ipv4/tcp_child_ehash_entries",
) -> Dict[str, Any]:
    sockstat = parse_sockstat(sockstat_file)
    ehash_entries = read_sysctl_int(ehash_entries_file)
    child_ehash = read_sysctl_int(child_ehash_file)

    inuse = sockstat.get("inuse", 0)
    alloc = sockstat.get("alloc", 0)
    orphan = sockstat.get("orphan", 0)
    tw = sockstat.get("tw", 0)

    hash_utilization = (inuse / ehash_entries) if ehash_entries > 0 else 0.0

    issues = []
    status = "HEALTHY"
    healthy = True

    if hash_utilization > 0.80:
        status = "WARNING"
        healthy = False
        issues.append(
            f"High established hash table utilization: {inuse}/{ehash_entries} ({hash_utilization:.1%})"
        )

    if ehash_entries < 1024:
        status = "WARNING"
        healthy = False
        issues.append(f"Dangerously low tcp_ehash_entries ({ehash_entries}), risk of severe hash collisions")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_ehash_entries": ehash_entries,
        "tcp_child_ehash_entries": child_ehash,
        "tcp_inuse": inuse,
        "tcp_alloc": alloc,
        "tcp_orphan": orphan,
        "tcp_tw": tw,
        "hash_utilization_pct": round(hash_utilization * 100, 4),
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sockstat": sockstat,
        "sysctls": {
            "tcp_ehash_entries": ehash_entries,
            "tcp_child_ehash_entries": child_ehash,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Established Socket Hash Table Guard (Pattern 166)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_ehash()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Established Hash Guard (Pattern 166) - Status: {s['status']}")
    print(f"  ehash Hash Table Buckets:  {s['tcp_ehash_entries']:,}")
    print(f"  Active In-Use TCP Sockets: {s['tcp_inuse']:,} ({s['hash_utilization_pct']}% bucket load)")
    print(f"  Allocated TCP Sockets:     {s['tcp_alloc']:,}")
    print(f"  Orphan Sockets:            {s['tcp_orphan']}")
    print(f"  TIME-WAIT Sockets:         {s['tcp_tw']:,}")
    print(f"  child_ehash_entries:       {s['tcp_child_ehash_entries']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
