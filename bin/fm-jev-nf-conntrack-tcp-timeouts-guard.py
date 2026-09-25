#!/usr/bin/env python3
"""
bin/fm-jev-nf-conntrack-tcp-timeouts-guard.py - Host Network Netfilter TCP Connection Tracking State Machine Timeouts Guard (Pattern 274 / Pattern 412)

Audits Linux kernel Netfilter TCP connection tracking state transition lifetimes:
  - /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_syn_sent: SYN_SENT state timeout (default 120s)
  - /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_syn_recv: SYN_RECV state timeout (default 60s)
  - /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established: ESTABLISHED state timeout (default 432000s = 5 days)
  - /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_fin_wait: FIN_WAIT state timeout (default 120s)
  - /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_close_wait: CLOSE_WAIT state timeout (default 60s)
  - /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_last_ack: LAST_ACK state timeout (default 30s)
  - /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_time_wait: TIME_WAIT state timeout (default 120s)
  - /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_close: CLOSE state timeout (default 10s)
  - /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_max_retrans: MAX_RETRANS state timeout (default 300s)
  - /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_unacknowledged: UNACKNOWLEDGED state timeout (default 300s)
  - /proc/sys/net/netfilter/nf_conntrack_count: Active tracked connections
  - /proc/sys/net/netfilter/nf_conntrack_max: Maximum table capacity

Invariants:
  - Established timeout >= 3600s (prevent dropping long-running idle agent connections).
  - SYN_SENT timeout <= 300s and SYN_RECV timeout <= 180s (mitigate half-open table exhaustion).
  - Table saturation < 80% (warning) and < 90% (critical).
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths are missing.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

PROC_NETFILTER_DIR = "/proc/sys/net/netfilter"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content else default
    except (ValueError, OSError, IndexError):
        return default


def audit_nf_conntrack_tcp_timeouts_guard(
    conf_dir: str = PROC_NETFILTER_DIR,
    warn_saturation_pct: float = 75.0,
    crit_saturation_pct: float = 90.0,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    if not os.path.isdir(conf_dir):
        return {
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "status": "UNKNOWN",
            "healthy": True,
            "conf_dir": conf_dir,
            "error": "Netfilter sysctl directory not found (conntrack module not loaded)",
            "issues": [],
            "recommendations": [],
        }

    syn_sent = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_tcp_timeout_syn_sent"), 120)
    syn_recv = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_tcp_timeout_syn_recv"), 60)
    established = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_tcp_timeout_established"), 432000)
    fin_wait = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_tcp_timeout_fin_wait"), 120)
    close_wait = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_tcp_timeout_close_wait"), 60)
    last_ack = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_tcp_timeout_last_ack"), 30)
    time_wait = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_tcp_timeout_time_wait"), 120)
    close = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_tcp_timeout_close"), 10)
    max_retrans = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_tcp_timeout_max_retrans"), 300)
    unack = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_tcp_timeout_unacknowledged"), 300)

    conntrack_count = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_count"), 0)
    conntrack_max = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_max"), 262144)

    saturation_pct = 0.0
    if conntrack_max > 0:
        saturation_pct = round((conntrack_count / conntrack_max) * 100.0, 3)

    if syn_sent > 300:
        issues.append(f"Excessive TCP SYN_SENT timeout ({syn_sent}s > 300s) risks table exhaustion from dead handshakes")
        recommendations.append("Reduce nf_conntrack_tcp_timeout_syn_sent to 120s")
    elif syn_sent < 10 and syn_sent != -1:
        issues.append(f"Abnormally low TCP SYN_SENT timeout ({syn_sent}s < 10s) may drop legitimate handshakes")
        recommendations.append("Restore nf_conntrack_tcp_timeout_syn_sent to 120s")

    if syn_recv > 180:
        issues.append(f"Excessive TCP SYN_RECV timeout ({syn_recv}s > 180s) increases SYN-flood vulnerability")
        recommendations.append("Reduce nf_conntrack_tcp_timeout_syn_recv to 60s")
    elif syn_recv < 10 and syn_recv != -1:
        issues.append(f"Abnormally low TCP SYN_RECV timeout ({syn_recv}s < 10s)")
        recommendations.append("Restore nf_conntrack_tcp_timeout_syn_recv to 60s")

    if established < 3600 and established != -1:
        issues.append(f"Low TCP established timeout ({established}s < 3600s) risks dropping long-lived idle sessions")
        recommendations.append("Increase nf_conntrack_tcp_timeout_established to at least 3600s (default 432000s)")

    if close_wait > 180:
        issues.append(f"Excessive TCP CLOSE_WAIT timeout ({close_wait}s > 180s) retains dead sockets")
        recommendations.append("Reduce nf_conntrack_tcp_timeout_close_wait to 60s")

    if time_wait > 240:
        issues.append(f"Excessive TCP TIME_WAIT timeout ({time_wait}s > 240s) delays conntrack state recycling")
        recommendations.append("Reduce nf_conntrack_tcp_timeout_time_wait to 120s (2*MSL)")

    if saturation_pct >= crit_saturation_pct:
        issues.append(f"Critical conntrack table saturation: {saturation_pct}% ({conntrack_count}/{conntrack_max})")
        recommendations.append("Tune TCP conntrack timeouts down or increase nf_conntrack_max")
        status = "CRITICAL"
    elif saturation_pct >= warn_saturation_pct:
        issues.append(f"High conntrack table saturation: {saturation_pct}% ({conntrack_count}/{conntrack_max})")
        recommendations.append("Monitor active TCP session durations and consider reducing idle timeouts")
        if status != "CRITICAL":
            status = "WARNING"

    if issues and status == "HEALTHY":
        status = "WARNING"

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timeout_syn_sent": syn_sent,
        "timeout_syn_recv": syn_recv,
        "timeout_established": established,
        "timeout_fin_wait": fin_wait,
        "timeout_close_wait": close_wait,
        "timeout_last_ack": last_ack,
        "timeout_time_wait": time_wait,
        "timeout_close": close,
        "timeout_max_retrans": max_retrans,
        "timeout_unacknowledged": unack,
        "conntrack_count": conntrack_count,
        "conntrack_max": conntrack_max,
        "table_saturation_pct": saturation_pct,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network Netfilter TCP Connection Tracking State Machine Timeouts Guard (Pattern 274 / Pattern 412)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--conf-dir", default=PROC_NETFILTER_DIR, help="Path to netfilter sysctl directory")
    parser.add_argument("--warn-saturation", type=float, default=75.0, help="Warning threshold for table saturation pct")
    parser.add_argument("--crit-saturation", type=float, default=90.0, help="Critical threshold for table saturation pct")
    args = parser.parse_args()

    res = audit_nf_conntrack_tcp_timeouts_guard(
        conf_dir=args.conf_dir,
        warn_saturation_pct=args.warn_saturation,
        crit_saturation_pct=args.crit_saturation,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        status_sym = "✓" if res["healthy"] else "✗"
        print(f"[{status_sym}] Netfilter TCP Timeouts Guard: {res['status']}")
        if "error" in res:
            print(f"    Notice: {res['error']}")
        else:
            print(f"    Established: {res['timeout_established']}s | SYN_SENT: {res['timeout_syn_sent']}s | SYN_RECV: {res['timeout_syn_recv']}s")
            print(f"    FIN_WAIT: {res['timeout_fin_wait']}s | CLOSE_WAIT: {res['timeout_close_wait']}s | TIME_WAIT: {res['timeout_time_wait']}s")
            print(f"    CLOSE: {res['timeout_close']}s | MAX_RETRANS: {res['timeout_max_retrans']}s | UNACK: {res['timeout_unacknowledged']}s")
            print(f"    Conntrack Table: {res['conntrack_count']} / {res['conntrack_max']} ({res['table_saturation_pct']}%)")
        if res["issues"]:
            print("    Issues:")
            for iss in res["issues"]:
                print(f"      - {iss}")
        if res["recommendations"]:
            print("    Recommendations:")
            for rec in res["recommendations"]:
                print(f"      - {rec}")

    return 0 if res["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
