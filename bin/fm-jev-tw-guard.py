#!/usr/bin/env python3
"""
fm-jev-tw-guard.py - Jev Multi-Agent TCP TIME_WAIT Bucket & Socket Port Reuse Guard (Pattern 72)

Audits Linux kernel TCP TIME_WAIT connection buckets, port allocation pressure, and socket reuse sysctls.
Monitors /proc/net/sockstat, /proc/sys/net/ipv4/tcp_max_tw_buckets, and tcp_tw_reuse to prevent
TIME_WAIT bucket exhaustion from dropping incoming connections or causing EADDRNOTAVAIL during
high-frequency multi-agent API polling and SSE streaming.

Invariants:
  - Read-only diagnostics. Non-destructive.
  - Fail-open: graceful handling on systems with non-standard procfs.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_WARN_TW_COUNT = 10000
DEFAULT_WARN_SATURATION_RATIO = 0.20
DEFAULT_CRIT_SATURATION_RATIO = 0.80

SOCKSTAT_PATH = "/proc/net/sockstat"
TCP_MAX_TW_BUCKETS_PATH = "/proc/sys/net/ipv4/tcp_max_tw_buckets"
TCP_TW_REUSE_PATH = "/proc/sys/net/ipv4/tcp_tw_reuse"
TCP_FIN_TIMEOUT_PATH = "/proc/sys/net/ipv4/tcp_fin_timeout"


def read_sysctl_int(path: str, default: int = 0) -> int:
    """Reads integer sysctl."""
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r") as f:
            return int(f.read().strip())
    except Exception:
        return default


def parse_sockstat_tw(path: str = SOCKSTAT_PATH) -> Dict[str, int]:
    """Parses TCP line in /proc/net/sockstat for inuse, orphan, tw, and alloc."""
    res = {"inuse": 0, "orphan": 0, "tw": 0, "alloc": 0, "mem": 0}
    if not os.path.exists(path):
        return res

    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 2 and parts[0] == "TCP:":
                    i = 1
                    while i < len(parts) - 1:
                        k = parts[i]
                        v = parts[i + 1]
                        if k in res:
                            try:
                                res[k] = int(v)
                            except ValueError:
                                pass
                        i += 2
    except Exception:
        pass

    return res


def audit_tw_buckets(
    sockstat_path: str = SOCKSTAT_PATH,
    max_tw_path: str = TCP_MAX_TW_BUCKETS_PATH,
    tw_reuse_path: str = TCP_TW_REUSE_PATH,
    fin_timeout_path: str = TCP_FIN_TIMEOUT_PATH,
    warn_tw_count: int = DEFAULT_WARN_TW_COUNT,
    warn_sat_ratio: float = DEFAULT_WARN_SATURATION_RATIO,
    crit_sat_ratio: float = DEFAULT_CRIT_SATURATION_RATIO,
) -> Dict[str, Any]:
    """Performs full audit of TCP TIME_WAIT buckets and socket reuse settings."""
    tcp_stat = parse_sockstat_tw(sockstat_path)
    max_tw = read_sysctl_int(max_tw_path, default=262144)
    tw_reuse = read_sysctl_int(tw_reuse_path, default=2)
    fin_timeout = read_sysctl_int(fin_timeout_path, default=60)

    tw_count = tcp_stat["tw"]
    sat_ratio = (tw_count / max_tw) if max_tw > 0 else 0.0

    status = "HEALTHY"
    recommendation = "TCP TIME_WAIT socket bucket utilization and port reuse settings are nominal."

    if sat_ratio >= crit_sat_ratio or (max_tw > 0 and tw_count >= max_tw):
        status = "CRITICAL"
        recommendation = (
            f"TCP TIME_WAIT bucket saturation is critical: {tw_count:,} sockets ({sat_ratio*100:.1f}% of max {max_tw:,}). "
            "Kernel is actively dropping TCP connections or failing socket allocations. Increase tcp_max_tw_buckets or verify tcp_tw_reuse."
        )
    elif sat_ratio >= warn_sat_ratio or tw_count >= warn_tw_count:
        status = "WARNING"
        recommendation = (
            f"Elevated TIME_WAIT sockets: {tw_count:,} sockets ({sat_ratio*100:.1f}% of max {max_tw:,}). "
            "Monitor outbound socket churn across multi-agent processes."
        )
    elif tw_reuse == 0:
        status = "WARNING"
        recommendation = (
            f"tcp_tw_reuse is disabled (0). Recommend enabling tcp_tw_reuse=2 to permit safe outbound "
            "ephemeral port recycling during high-frequency API traffic."
        )

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": (status == "HEALTHY"),
            "tcp_tw_count": tw_count,
            "tcp_max_tw_buckets": max_tw,
            "tw_saturation_ratio": round(sat_ratio, 4),
            "tcp_tw_reuse": tw_reuse,
            "tcp_fin_timeout": fin_timeout,
            "tcp_inuse": tcp_stat["inuse"],
            "tcp_orphan": tcp_stat["orphan"],
            "tcp_alloc": tcp_stat["alloc"],
            "recommendation": recommendation,
        },
        "tcp_stat": tcp_stat,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent TCP TIME_WAIT Bucket & Socket Port Reuse Guard (Pattern 72)"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument(
        "--warn-tw-count",
        type=int,
        default=DEFAULT_WARN_TW_COUNT,
        help=f"Warn threshold for TIME_WAIT count (default: {DEFAULT_WARN_TW_COUNT})",
    )
    parser.add_argument(
        "--warn-sat-ratio",
        type=float,
        default=DEFAULT_WARN_SATURATION_RATIO,
        help=f"Warn threshold for saturation ratio (default: {DEFAULT_WARN_SATURATION_RATIO})",
    )

    args = parser.parse_args()

    report = audit_tw_buckets(
        warn_tw_count=args.warn_tw_count,
        warn_sat_ratio=args.warn_sat_ratio,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"[{s['status']}] Jev TCP TIME_WAIT Bucket Guard (Pattern 72)")
        print(f"TIME_WAIT Sockets: {s['tcp_tw_count']:,} / {s['tcp_max_tw_buckets']:,} max ({s['tw_saturation_ratio']*100:.2f}% saturation)")
        print(f"Active TCP: {s['tcp_inuse']:,} inuse | {s['tcp_orphan']:,} orphan | {s['tcp_alloc']:,} alloc")
        print(f"Sysctls: tcp_tw_reuse={s['tcp_tw_reuse']} | tcp_fin_timeout={s['tcp_fin_timeout']}s")
        print(f"Status: {s['status']}")
        print(f"Recommendation: {s['recommendation']}")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
