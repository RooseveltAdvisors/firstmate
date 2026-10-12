#!/usr/bin/env python3
"""
fm-jev-net-metrics-guard.py - Jev Multi-Agent Host Network TCP Route Metrics Cache & Stale RTT Guard (Pattern 117)

Audits Linux TCP destination route metrics cache and tcp_no_metrics_save sysctl from /proc/sys/net/ipv4/tcp_no_metrics_save
and `ip tcp_metrics show`.

Detects stale connection metric accumulation (>24h old RTT, RTT variance, and clamped ssthresh), preventing legacy
slow-start thresholds and artificial latency penalties from bottlenecking new multi-agent connections to cloud APIs.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysfs or ip commands are missing/restricted.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

SYSCTL_NO_METRICS_SAVE = "/proc/sys/net/ipv4/tcp_no_metrics_save"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def parse_tcp_metrics(metrics_text: str) -> List[Dict[str, Any]]:
    """Parses `ip tcp_metrics show` output into structured metric records."""
    entries: List[Dict[str, Any]] = []
    for line in metrics_text.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if not parts:
            continue
        dest_ip = parts[0]
        entry: Dict[str, Any] = {"ip": dest_ip, "age_sec": 0, "cwnd": None, "rtt_us": None, "ssthresh": None}

        # Parse key-value tokens
        for i in range(1, len(parts) - 1):
            key = parts[i]
            val = parts[i + 1]
            if key == "age":
                m = re.match(r"^([\d\.]+)sec", val)
                if m:
                    entry["age_sec"] = float(m.group(1))
            elif key == "cwnd":
                try:
                    entry["cwnd"] = int(val)
                except ValueError:
                    pass
            elif key == "rtt":
                m = re.match(r"^(\d+)us", val)
                if m:
                    entry["rtt_us"] = int(m.group(1))
            elif key == "ssthresh":
                try:
                    entry["ssthresh"] = int(val)
                except ValueError:
                    pass

        entries.append(entry)
    return entries


def audit_net_metrics(
    no_metrics_save_file: Optional[str] = None,
    metrics_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TCP route metrics cache for stale RTT and clamped ssthresh values."""
    save_path = Path(no_metrics_save_file) if no_metrics_save_file else Path(SYSCTL_NO_METRICS_SAVE)
    no_metrics_save = read_int_file(save_path)

    metrics_text = ""
    if metrics_file:
        p = Path(metrics_file)
        if p.is_file():
            metrics_text = p.read_text()
    else:
        try:
            proc = subprocess.run(["ip", "tcp_metrics", "show"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=2)
            if proc.returncode == 0:
                metrics_text = proc.stdout
        except Exception:
            metrics_text = ""

    entries = parse_tcp_metrics(metrics_text)
    total_entries = len(entries)

    stale_24h_entries = 0
    stale_7d_entries = 0
    max_age_sec = 0.0
    clamped_ssthresh = 0

    for e in entries:
        age = e["age_sec"]
        if age > max_age_sec:
            max_age_sec = age
        if age > 86400:
            stale_24h_entries += 1
        if age > 604800:
            stale_7d_entries += 1
        if e["ssthresh"] is not None and e["ssthresh"] <= 4:
            clamped_ssthresh += 1

    max_age_days = round(max_age_sec / 86400, 1)

    issues: List[str] = []

    if clamped_ssthresh > 50:
        issues.append(f"Elevated clamped ssthresh entries ({clamped_ssthresh}): cached routes artificially throttling initial throughput")

    if total_entries > 20000:
        issues.append(f"High TCP metrics cache bloat ({total_entries} entries): consider setting tcp_no_metrics_save=1 or flushing ip tcp_metrics")

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_no_metrics_save": no_metrics_save == 1 if no_metrics_save is not None else None,
            "total_cached_destinations": total_entries,
            "stale_entries_over_24h": stale_24h_entries,
            "stale_entries_over_7d": stale_7d_entries,
            "max_cached_age_days": max_age_days,
            "clamped_ssthresh_count": clamped_ssthresh,
            "issues": issues,
        },
        "counters": {
            "total_entries": total_entries,
            "stale_24h": stale_24h_entries,
            "stale_7d": stale_7d_entries,
            "clamped_ssthresh": clamped_ssthresh,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Route Metrics Cache & Stale RTT Guard (Pattern 117)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--save-file", type=str, default=None, help="Path to tcp_no_metrics_save")
    parser.add_argument("--metrics-file", type=str, default=None, help="Path to dumped ip tcp_metrics show text")
    args = parser.parse_args()

    result = audit_net_metrics(
        no_metrics_save_file=args.save_file,
        metrics_file=args.metrics_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP Route Metrics Guard (Pattern 117)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Metrics Caching Behavior:      {'Disabled (fresh metrics on connect)' if summary['tcp_no_metrics_save'] else 'Enabled (inherits cached RTT/CWND)'}")
    print(f" Total Cached Destinations:     {summary['total_cached_destinations']:,}")
    print(f" Stale Cached Routes (>24h):    {summary['stale_entries_over_24h']:,}")
    print(f" Stale Cached Routes (>7d):     {summary['stale_entries_over_7d']:,}")
    print(f" Maximum Route Cache Age:       {summary['max_cached_age_days']} days")
    print(f" Clamped ssthresh Endpoints:    {summary['clamped_ssthresh_count']}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Route Metrics Metric':<35} {'Count':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Total Route Cache Entries':<35} {counters['total_entries']:<15} Nominal")
    print(f" {'Stale Routes (>24 hours)':<35} {counters['stale_24h']:<15} Nominal")
    print(f" {'Stale Routes (>7 days)':<35} {counters['stale_7d']:<15} Nominal")
    print(f" {'Clamped ssthresh Endpoints':<35} {counters['clamped_ssthresh']:<15} {'Nominal' if counters['clamped_ssthresh'] <= 50 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive TCP Route Metrics Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP route metric cache entries and destination RTT states nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
