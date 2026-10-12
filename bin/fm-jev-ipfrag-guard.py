#!/usr/bin/env python3
"""
fm-jev-ipfrag-guard.py - Jev Multi-Agent Host Network IP Packet Fragment Reassembly Guard (Pattern 126)

Audits Linux IP packet fragment reassembly memory limits (/proc/sys/net/ipv4/ipfrag_high_thresh,
/proc/sys/net/ipv4/ipfrag_low_thresh, /proc/sys/net/ipv4/ipfrag_time), in-flight fragment socket memory
from /proc/net/sockstat, and SNMP reassembly/fragmentation failure counters from /proc/net/snmp.

In multi-agent telemetry clusters, large payload UDP/RPC datagrams exceeding MTU trigger IP-level
fragmentation. If fragment buffer memory exhausts, kernel drops fragments and triggers severe CPU
garbage collection spikes and silent packet loss.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysctl or procfs entries are inaccessible.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SYSCTL_HIGH_THRESH = "/proc/sys/net/ipv4/ipfrag_high_thresh"
SYSCTL_LOW_THRESH = "/proc/sys/net/ipv4/ipfrag_low_thresh"
SYSCTL_TIME = "/proc/sys/net/ipv4/ipfrag_time"
SYSCTL_MAX_DIST = "/proc/sys/net/ipv4/ipfrag_max_dist"

PROC_SOCKSTAT = "/proc/net/sockstat"
PROC_SNMP = "/proc/net/snmp"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def parse_proc_pairs(path: Path, section_name: str) -> Dict[str, int]:
    """Parses paired header/metric lines from /proc/net/snmp."""
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
        return {}

    return metrics


def parse_frag_sockstat(path: Path) -> Tuple[int, int]:
    """Parses inuse and memory from FRAG line in /proc/net/sockstat."""
    if not path.is_file():
        return 0, 0

    try:
        lines = path.read_text().splitlines()
        for line in lines:
            if line.startswith("FRAG:"):
                inuse_match = re.search(r"inuse\s+(\d+)", line)
                mem_match = re.search(r"memory\s+(\d+)", line)
                inuse = int(inuse_match.group(1)) if inuse_match else 0
                mem = int(mem_match.group(1)) if mem_match else 0
                return inuse, mem
    except Exception:
        return 0, 0

    return 0, 0


def audit_ipfrag(
    high_thresh_file: Optional[str] = None,
    low_thresh_file: Optional[str] = None,
    time_file: Optional[str] = None,
    max_dist_file: Optional[str] = None,
    sockstat_file: Optional[str] = None,
    snmp_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host IP fragment reassembly thresholds, queue memory, and failure counters."""
    high_p = Path(high_thresh_file or SYSCTL_HIGH_THRESH)
    low_p = Path(low_thresh_file or SYSCTL_LOW_THRESH)
    time_p = Path(time_file or SYSCTL_TIME)
    dist_p = Path(max_dist_file or SYSCTL_MAX_DIST)

    sockstat_p = Path(sockstat_file or PROC_SOCKSTAT)
    snmp_p = Path(snmp_file or PROC_SNMP)

    high_thresh = read_int_file(high_p)
    if high_thresh is None:
        high_thresh = 4194304  # 4MB

    low_thresh = read_int_file(low_p)
    if low_thresh is None:
        low_thresh = 3145728  # 3MB

    frag_time = read_int_file(time_p)
    if frag_time is None:
        frag_time = 30

    max_dist = read_int_file(dist_p)
    if max_dist is None:
        max_dist = 64

    frag_inuse, frag_memory = parse_frag_sockstat(sockstat_p)

    ip_metrics = parse_proc_pairs(snmp_p, "Ip")
    reasm_reqds = ip_metrics.get("ReasmReqds", 0)
    reasm_oks = ip_metrics.get("ReasmOKs", 0)
    reasm_fails = ip_metrics.get("ReasmFails", 0)
    reasm_timeout = ip_metrics.get("ReasmTimeout", 0)
    frag_oks = ip_metrics.get("FragOKs", 0)
    frag_fails = ip_metrics.get("FragFails", 0)
    frag_creates = ip_metrics.get("FragCreates", 0)

    issues: List[str] = []
    healthy = True

    if frag_memory >= high_thresh and high_thresh > 0:
        healthy = False
        issues.append(f"IP fragment memory saturated: {frag_memory:,} bytes >= high threshold {high_thresh:,} bytes. Incoming fragments dropped.")
    elif frag_memory >= low_thresh and low_thresh > 0:
        issues.append(f"IP fragment memory elevated: {frag_memory:,} bytes >= low threshold {low_thresh:,} bytes. Garbage collection active.")

    if reasm_fails > 1000:
        healthy = False
        issues.append(f"Elevated IP fragment reassembly failures ({reasm_fails:,} datagrams). Fragment packet loss or aggressive timeout.")

    if reasm_timeout > 500:
        healthy = False
        issues.append(f"High fragment reassembly timeouts ({reasm_timeout:,} timeouts). Fragments arriving beyond {frag_time}s limit.")

    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "high_thresh_bytes": high_thresh,
            "low_thresh_bytes": low_thresh,
            "frag_time_sec": frag_time,
            "frag_inuse": frag_inuse,
            "frag_memory_bytes": frag_memory,
            "reasm_reqds": reasm_reqds,
            "reasm_oks": reasm_oks,
            "reasm_fails": reasm_fails,
            "reasm_timeout": reasm_timeout,
            "frag_fails": frag_fails,
            "issues": issues,
        },
        "counters": {
            "frag_inuse": frag_inuse,
            "frag_memory_bytes": frag_memory,
            "reasm_reqds": reasm_reqds,
            "reasm_oks": reasm_oks,
            "reasm_fails": reasm_fails,
            "reasm_timeout": reasm_timeout,
            "frag_oks": frag_oks,
            "frag_fails": frag_fails,
            "frag_creates": frag_creates,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network IP Packet Fragment Reassembly Guard (Pattern 126)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--high-thresh-file", type=str, default=None, help="Path to ipfrag_high_thresh")
    parser.add_argument("--low-thresh-file", type=str, default=None, help="Path to ipfrag_low_thresh")
    parser.add_argument("--time-file", type=str, default=None, help="Path to ipfrag_time")
    parser.add_argument("--max-dist-file", type=str, default=None, help="Path to ipfrag_max_dist")
    parser.add_argument("--sockstat-file", type=str, default=None, help="Path to /proc/net/sockstat")
    parser.add_argument("--snmp-file", type=str, default=None, help="Path to /proc/net/snmp")
    args = parser.parse_args()

    result = audit_ipfrag(
        high_thresh_file=args.high_thresh_file,
        low_thresh_file=args.low_thresh_file,
        time_file=args.time_file,
        max_dist_file=args.max_dist_file,
        sockstat_file=args.sockstat_file,
        snmp_file=args.snmp_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network IP Fragment Reassembly Guard (Pattern 126)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" High Reassembly Threshold:     {summary['high_thresh_bytes']:,} bytes ({summary['high_thresh_bytes'] // 1048576} MiB)")
    print(f" Low Garbage-Collect Threshold: {summary['low_thresh_bytes']:,} bytes ({summary['low_thresh_bytes'] // 1048576} MiB)")
    print(f" Fragment Reassembly Timeout:   {summary['frag_time_sec']}s")
    print(f" In-Flight Fragment Queues:     {summary['frag_inuse']}")
    print(f" In-Flight Fragment Memory:     {summary['frag_memory_bytes']:,} bytes")
    print(f" Reassembly Requests (Reqds):   {counters['reasm_reqds']:,}")
    print(f" Reassembled Successfully (OKs):{counters['reasm_oks']:,}")
    print(f" Reassembly Failures (Fails):   {counters['reasm_fails']:,}")
    print(f" Reassembly Timeouts:           {counters['reasm_timeout']:,}")
    print(f" Datagram Fragmentation Fails:  {counters['frag_fails']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'IP Fragmentation Metric':<35} {'Count / Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Fragment Memory Usage':<35} {summary['frag_memory_bytes']:<15} {'Nominal' if summary['frag_memory_bytes'] < summary['low_thresh_bytes'] else 'WARNING'}")
    print(f" {'In-Flight Fragment Sockets':<35} {summary['frag_inuse']:<15} Nominal")
    print(f" {'Reassembly Failures':<35} {counters['reasm_fails']:<15} {'Nominal' if counters['reasm_fails'] <= 1000 else 'WARNING'}")
    print(f" {'Reassembly Timeouts':<35} {counters['reasm_timeout']:<15} {'Nominal' if counters['reasm_timeout'] <= 500 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive IP Fragmentation Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host IP fragment memory buffers, reassembly queues, and SNMP counters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
