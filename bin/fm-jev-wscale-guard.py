#!/usr/bin/env python3
"""
bin/fm-jev-wscale-guard.py - Host Network TCP Window Scale & Buffer Footprint Guard (Pattern 157)

Audits tcp_window_scaling, tcp_wmem, tcp_rmem, and netstat window probe counters
(TCPZeroWindowDrop, TCPWinProbe, BeyondWindow) to verify RFC 7323 window scale factor
allocation and buffer auto-tuning headroom, preventing sliding window throughput
bottlenecks across high-bandwidth agent token channels.
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


def read_sysctl_triplet(path: str) -> List[int]:
    if not os.path.exists(path):
        return []
    try:
        with open(path, "r", encoding="utf-8") as f:
            parts = f.read().strip().split()
            return [int(p) for p in parts]
    except Exception as e:
        print(f"Warning: unable to read {path}: {e}", file=sys.stderr)
        return []


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


def audit_wscale(
    wscale_file: str = "/proc/sys/net/ipv4/tcp_window_scaling",
    wmem_file: str = "/proc/sys/net/ipv4/tcp_wmem",
    rmem_file: str = "/proc/sys/net/ipv4/tcp_rmem",
    adv_win_file: str = "/proc/sys/net/ipv4/tcp_adv_win_scale",
    app_win_file: str = "/proc/sys/net/ipv4/tcp_app_win",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    wscale = read_sysctl_int(wscale_file)
    wmem = read_sysctl_triplet(wmem_file)
    rmem = read_sysctl_triplet(rmem_file)
    adv_win = read_sysctl_int(adv_win_file)
    app_win = read_sysctl_int(app_win_file)
    netstat = parse_netstat(netstat_file)

    zero_win_drop = netstat.get("TCPZeroWindowDrop", 0)
    win_probes = netstat.get("TCPWinProbe", 0)
    beyond_win = netstat.get("BeyondWindow", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    if wscale == 0:
        status = "WARNING"
        healthy = False
        issues.append("tcp_window_scaling is disabled (0), limiting TCP window to 64 KiB maximum")
    elif wscale < 0:
        issues.append(f"Unable to read tcp_window_scaling from {wscale_file}")

    if rmem and len(rmem) == 3:
        max_rmem = rmem[2]
        if max_rmem < 1_048_576:  # Less than 1 MiB
            status = "WARNING"
            healthy = False
            issues.append(f"Max receive buffer is low: {max_rmem} bytes (< 1 MiB)")

    if zero_win_drop > 0:
        status = "WARNING"
        healthy = False
        issues.append(f"Detected zero-window packet drops: {zero_win_drop}")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_window_scaling": wscale,
        "tcp_wmem": wmem,
        "tcp_rmem": rmem,
        "tcp_adv_win_scale": adv_win,
        "tcp_app_win": app_win,
        "zero_win_drop": zero_win_drop,
        "win_probes": win_probes,
        "beyond_win": beyond_win,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "counters": {
            "tcp_window_scaling": wscale,
            "zero_win_drop": zero_win_drop,
            "win_probes": win_probes,
            "beyond_win": beyond_win,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Window Scale & Buffer Footprint Guard (Pattern 157)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_wscale()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Window Scale Guard (Pattern 157) - Status: {s['status']}")
    print(f"  tcp_window_scaling:        {s['tcp_window_scaling']} (1 = RFC 7323 window scale enabled)")
    if s["tcp_rmem"] and len(s["tcp_rmem"]) == 3:
        rm = s["tcp_rmem"]
        print(f"  tcp_rmem (min/def/max):    {rm[0]:,} / {rm[1]:,} / {rm[2]:,} bytes ({rm[2] // (1024*1024)} MiB max)")
    if s["tcp_wmem"] and len(s["tcp_wmem"]) == 3:
        wm = s["tcp_wmem"]
        print(f"  tcp_wmem (min/def/max):    {wm[0]:,} / {wm[1]:,} / {wm[2]:,} bytes ({wm[2] // (1024*1024)} MiB max)")
    print(f"  adv_win_scale / app_win:   {s['tcp_adv_win_scale']} / {s['tcp_app_win']}")
    print(f"  Zero Window Drops:         {s['zero_win_drop']}")
    print(f"  Window Probes Sent:        {s['win_probes']:,}")
    print(f"  Beyond Window Packets:     {s['beyond_win']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
