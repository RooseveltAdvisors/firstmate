#!/usr/bin/env python3
"""
bin/fm-jev-tcp-metrics-guard.py - Host Network TCP Metrics Cache Stale Entry & Metric Bloat Guard (Pattern 216)

Audits Linux kernel TCP metrics cache and slow start threshold persistence:
  - 'ip tcp_metrics show' (Cached destination metrics: cwnd, ssthresh, rtt, rttvar, age)
  - /proc/sys/net/ipv4/tcp_no_metrics_save (Controls whether TCP metrics are saved to cache on close)

Detects stale TCP metrics table bloat, lingering suppressed CWND / high-RTT estimates from past
transient network congestion, and kernel memory accumulation across multi-agent RPC endpoints,
LLM API client connections, and container bridge networking.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when iproute2 tool or sysctl paths are restricted.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import datetime
import json
import os
import subprocess
import sys
from typing import Any, Dict, List, Optional


def read_sysctl_int(path: str, default: int = 0) -> int:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            c = f.read().strip()
            return int(c) if c.isdigit() else default
    except Exception:
        return default


def parse_tcp_metrics_lines(lines: List[str]) -> List[Dict[str, Any]]:
    entries: List[Dict[str, Any]] = []
    for line in lines:
        parts = line.strip().split()
        if not parts:
            continue
        dest_ip = parts[0]
        age_sec = 0.0
        cwnd = None
        ssthresh = None
        rtt_us = None
        rttvar_us = None
        source_ip = None

        i = 1
        while i < len(parts):
            token = parts[i]
            if token == "age" and i + 1 < len(parts):
                val_str = parts[i + 1].rstrip("sec")
                try:
                    age_sec = float(val_str)
                except ValueError:
                    pass
                i += 2
            elif token == "cwnd" and i + 1 < len(parts):
                try:
                    cwnd = int(parts[i + 1])
                except ValueError:
                    pass
                i += 2
            elif token == "ssthresh" and i + 1 < len(parts):
                try:
                    ssthresh = int(parts[i + 1])
                except ValueError:
                    pass
                i += 2
            elif token == "rtt" and i + 1 < len(parts):
                val_str = parts[i + 1].rstrip("us")
                try:
                    rtt_us = int(val_str)
                except ValueError:
                    pass
                i += 2
            elif token == "rttvar" and i + 1 < len(parts):
                val_str = parts[i + 1].rstrip("us")
                try:
                    rttvar_us = int(val_str)
                except ValueError:
                    pass
                i += 2
            elif token == "source" and i + 1 < len(parts):
                source_ip = parts[i + 1]
                i += 2
            else:
                i += 1

        entries.append({
            "dest_ip": dest_ip,
            "age_seconds": round(age_sec, 2),
            "age_days": round(age_sec / 86400.0, 2),
            "cwnd": cwnd,
            "ssthresh": ssthresh,
            "rtt_us": rtt_us,
            "rttvar_us": rttvar_us,
            "source_ip": source_ip,
        })
    return entries


def get_tcp_metrics_output(mock_file: Optional[str] = None) -> List[str]:
    if mock_file and os.path.exists(mock_file):
        try:
            with open(mock_file, "r", encoding="utf-8") as f:
                return f.readlines()
        except Exception:
            return []
    try:
        res = subprocess.run(
            ["ip", "tcp_metrics", "show"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
        )
        if res.returncode == 0:
            return res.stdout.splitlines()
    except Exception:
        pass
    return []


def audit_tcp_metrics(
    mock_file: Optional[str] = None,
    sysctl_file: str = "/proc/sys/net/ipv4/tcp_no_metrics_save",
    warn_entries: int = 5000,
    crit_entries: int = 15000,
    warn_stale_30d: int = 1000,
) -> Dict[str, Any]:
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines = get_tcp_metrics_output(mock_file)
    entries = parse_tcp_metrics_lines(lines)

    tcp_no_metrics_save = read_sysctl_int(sysctl_file, 0)

    total_entries = len(entries)
    entries_over_7d = sum(1 for e in entries if e["age_seconds"] >= 7 * 86400)
    entries_over_30d = sum(1 for e in entries if e["age_seconds"] >= 30 * 86400)
    max_age_sec = max((e["age_seconds"] for e in entries), default=0.0)
    max_age_days = round(max_age_sec / 86400.0, 2)

    low_cwnd_entries = [e for e in entries if e["cwnd"] is not None and e["cwnd"] < 10]
    high_rtt_entries = [e for e in entries if e["rtt_us"] is not None and e["rtt_us"] >= 500000]

    issues: List[str] = []
    status = "HEALTHY"

    if total_entries >= crit_entries:
        status = "CRITICAL"
        issues.append(f"TCP metrics cache critical capacity: {total_entries} entries (>= {crit_entries})")
    elif total_entries >= warn_entries:
        status = "WARNING"
        issues.append(f"TCP metrics cache elevated capacity: {total_entries} entries (>= {warn_entries})")

    if entries_over_30d >= warn_stale_30d and status != "CRITICAL":
        status = "WARNING"
        issues.append(f"High stale TCP metrics accumulation: {entries_over_30d} entries older than 30 days (>= {warn_stale_30d})")

    top_aged = sorted(entries, key=lambda x: x["age_seconds"], reverse=True)[:5]
    top_rtt = sorted(
        [e for e in entries if e["rtt_us"] is not None],
        key=lambda x: x["rtt_us"],
        reverse=True,
    )[:5]

    return {
        "timestamp": now,
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "total_entries": total_entries,
            "entries_over_7d": entries_over_7d,
            "entries_over_30d": entries_over_30d,
            "max_age_days": max_age_days,
            "low_cwnd_count": len(low_cwnd_entries),
            "high_rtt_count": len(high_rtt_entries),
            "tcp_no_metrics_save": tcp_no_metrics_save,
            "issues": issues,
        },
        "top_aged_entries": top_aged,
        "top_rtt_entries": top_rtt,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Host Network TCP Metrics Cache Stale Entry & Metric Bloat Guard (Pattern 216)"
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    parser.add_argument("--warn-entries", type=int, default=5000, help="Warning threshold for total entries (default: 5000)")
    parser.add_argument("--crit-entries", type=int, default=15000, help="Critical threshold for total entries (default: 15000)")
    parser.add_argument("--mock-file", type=str, default=None, help="Path to mock tcp_metrics output file")
    parser.add_argument("--sysctl-file", type=str, default="/proc/sys/net/ipv4/tcp_no_metrics_save", help="Path to tcp_no_metrics_save")

    args = parser.parse_args()

    report = audit_tcp_metrics(
        mock_file=args.mock_file,
        sysctl_file=args.sysctl_file,
        warn_entries=args.warn_entries,
        crit_entries=args.crit_entries,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"[{s['status']}] TCP Metrics: {s['total_entries']} entries | >7d: {s['entries_over_7d']} | >30d: {s['entries_over_30d']} | Max Age: {s['max_age_days']} days")
        print(f"  Low CWND (<10): {s['low_cwnd_count']} | High RTT (>=500ms): {s['high_rtt_count']} | tcp_no_metrics_save: {s['tcp_no_metrics_save']}")
        if report["top_aged_entries"]:
            print("  Top Aged Metrics:")
            for item in report["top_aged_entries"]:
                print(f"    - {item['dest_ip']}: {item['age_days']} days old, cwnd={item['cwnd']}, rtt={item['rtt_us']}us")
        if s["issues"]:
            print("  Issues:")
            for issue in s["issues"]:
                print(f"    - {issue}")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
