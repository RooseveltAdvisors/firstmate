#!/usr/bin/env python3
"""
bin/fm-jev-nf-conntrack-sctp-guard.py - Host Network Netfilter SCTP State Machine Timeouts Guard (Pattern 278 / Pattern 416)

Audits Linux kernel Netfilter SCTP association state transition lifetimes:
  - /proc/sys/net/netfilter/nf_conntrack_sctp_timeout_closed:
      CLOSED state timeout (default 10s).
  - /proc/sys/net/netfilter/nf_conntrack_sctp_timeout_cookie_wait:
      COOKIE_WAIT state timeout (default 3s).
  - /proc/sys/net/netfilter/nf_conntrack_sctp_timeout_cookie_echoed:
      COOKIE_ECHOED state timeout (default 3s).
  - /proc/sys/net/netfilter/nf_conntrack_sctp_timeout_established:
      ESTABLISHED state timeout (default 210s).
  - /proc/sys/net/netfilter/nf_conntrack_sctp_timeout_heartbeat_sent:
      HEARTBEAT_SENT state timeout (default 30s).
  - /proc/sys/net/netfilter/nf_conntrack_sctp_timeout_shutdown_sent:
      SHUTDOWN_SENT state timeout (default 3s).
  - /proc/sys/net/netfilter/nf_conntrack_sctp_timeout_shutdown_recd:
      SHUTDOWN_RECD state timeout (default 3s).
  - /proc/sys/net/netfilter/nf_conntrack_sctp_timeout_shutdown_ack_sent:
      SHUTDOWN_ACK_SENT state timeout (default 3s).
  - /proc/sys/net/netfilter/nf_conntrack_count / nf_conntrack_max:
      Table saturation calculation.

Invariants:
  - closed timeout between 1s and 60s.
  - cookie_wait / cookie_echoed between 1s and 30s.
  - established timeout between 30s and 86400s.
  - heartbeat_sent between 5s and 300s.
  - shutdown state timeouts between 1s and 60s.
  - table saturation < 75% (warning) and < 90% (critical).
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


def audit_nf_conntrack_sctp_guard(
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
            "error": "Netfilter sysctl directory not found",
            "issues": [],
            "recommendations": [],
        }

    closed = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_sctp_timeout_closed"), 10)
    cookie_wait = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_sctp_timeout_cookie_wait"), 3)
    cookie_echoed = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_sctp_timeout_cookie_echoed"), 3)
    established = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_sctp_timeout_established"), 210)
    heartbeat_sent = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_sctp_timeout_heartbeat_sent"), 30)
    shutdown_sent = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_sctp_timeout_shutdown_sent"), 3)
    shutdown_recd = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_sctp_timeout_shutdown_recd"), 3)
    shutdown_ack_sent = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_sctp_timeout_shutdown_ack_sent"), 3)

    conntrack_count = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_count"), 0)
    conntrack_max = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_max"), 262144)

    saturation_pct = 0.0
    if conntrack_max > 0:
        saturation_pct = round((conntrack_count / conntrack_max) * 100.0, 3)

    if closed > 60:
        issues.append(f"Excessive SCTP CLOSED timeout ({closed}s > 60s) delays conntrack state recycling")
        recommendations.append("Reduce nf_conntrack_sctp_timeout_closed to default 10s")
    elif closed < 1 and closed != -1:
        issues.append(f"Abnormally low SCTP CLOSED timeout ({closed}s < 1s)")
        recommendations.append("Restore nf_conntrack_sctp_timeout_closed to default 10s")

    if cookie_wait > 30:
        issues.append(f"Excessive SCTP COOKIE_WAIT timeout ({cookie_wait}s > 30s) risks table exhaustion from unacknowledged INIT handshakes")
        recommendations.append("Reduce nf_conntrack_sctp_timeout_cookie_wait to default 3s")
    elif cookie_wait < 1 and cookie_wait != -1:
        issues.append(f"Abnormally low SCTP COOKIE_WAIT timeout ({cookie_wait}s < 1s)")
        recommendations.append("Restore nf_conntrack_sctp_timeout_cookie_wait to default 3s")

    if cookie_echoed > 30:
        issues.append(f"Excessive SCTP COOKIE_ECHOED timeout ({cookie_echoed}s > 30s) risks state exhaustion during handshake completion")
        recommendations.append("Reduce nf_conntrack_sctp_timeout_cookie_echoed to default 3s")
    elif cookie_echoed < 1 and cookie_echoed != -1:
        issues.append(f"Abnormally low SCTP COOKIE_ECHOED timeout ({cookie_echoed}s < 1s)")
        recommendations.append("Restore nf_conntrack_sctp_timeout_cookie_echoed to default 3s")

    if established < 30 and established != -1:
        issues.append(f"Abnormally low SCTP established timeout ({established}s < 30s) risks dropping active associations prematurely")
        recommendations.append("Increase nf_conntrack_sctp_timeout_established to at least 210s")
    elif established > 86400:
        issues.append(f"Excessive SCTP established timeout ({established}s > 86400s) risks retaining stale conntrack entries")
        recommendations.append("Reduce nf_conntrack_sctp_timeout_established towards default 210s")

    if heartbeat_sent > 300:
        issues.append(f"Excessive SCTP HEARTBEAT_SENT timeout ({heartbeat_sent}s > 300s) delays dead path detection")
        recommendations.append("Reduce nf_conntrack_sctp_timeout_heartbeat_sent to default 30s")
    elif heartbeat_sent < 5 and heartbeat_sent != -1:
        issues.append(f"Abnormally low SCTP HEARTBEAT_SENT timeout ({heartbeat_sent}s < 5s)")
        recommendations.append("Restore nf_conntrack_sctp_timeout_heartbeat_sent to default 30s")

    for s_name, s_val in [
        ("shutdown_sent", shutdown_sent),
        ("shutdown_recd", shutdown_recd),
        ("shutdown_ack_sent", shutdown_ack_sent),
    ]:
        if s_val > 60:
            issues.append(f"Excessive SCTP {s_name.upper()} timeout ({s_val}s > 60s) retains terminating associations")
            recommendations.append(f"Reduce nf_conntrack_sctp_timeout_{s_name} to default 3s")
        elif s_val < 1 and s_val != -1:
            issues.append(f"Abnormally low SCTP {s_name.upper()} timeout ({s_val}s < 1s)")
            recommendations.append(f"Restore nf_conntrack_sctp_timeout_{s_name} to default 3s")

    if saturation_pct >= crit_saturation_pct:
        issues.append(f"Critical conntrack table saturation: {saturation_pct}% ({conntrack_count}/{conntrack_max})")
        recommendations.append("Tune SCTP/TCP conntrack timeouts down or increase nf_conntrack_max")
        status = "CRITICAL"
    elif saturation_pct >= warn_saturation_pct:
        issues.append(f"High conntrack table saturation: {saturation_pct}% ({conntrack_count}/{conntrack_max})")
        recommendations.append("Monitor active SCTP/TCP association lifetimes and consider reducing idle timeouts")
        if status != "CRITICAL":
            status = "WARNING"

    if issues and status == "HEALTHY":
        status = "WARNING"

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timeout_closed": closed,
        "timeout_cookie_wait": cookie_wait,
        "timeout_cookie_echoed": cookie_echoed,
        "timeout_established": established,
        "timeout_heartbeat_sent": heartbeat_sent,
        "timeout_shutdown_sent": shutdown_sent,
        "timeout_shutdown_recd": shutdown_recd,
        "timeout_shutdown_ack_sent": shutdown_ack_sent,
        "conntrack_count": conntrack_count,
        "conntrack_max": conntrack_max,
        "table_saturation_pct": saturation_pct,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network Netfilter SCTP State Machine Timeouts Guard (Pattern 278 / Pattern 416)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--conf-dir", default=PROC_NETFILTER_DIR, help="Path to netfilter sysctl directory")
    parser.add_argument("--warn-saturation", type=float, default=75.0, help="Warning threshold for table saturation pct")
    parser.add_argument("--crit-saturation", type=float, default=90.0, help="Critical threshold for table saturation pct")
    args = parser.parse_args()

    res = audit_nf_conntrack_sctp_guard(
        conf_dir=args.conf_dir,
        warn_saturation_pct=args.warn_saturation,
        crit_saturation_pct=args.crit_saturation,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        status_sym = "✓" if res["healthy"] else "✗"
        print(f"[{status_sym}] Netfilter SCTP Guard: {res['status']}")
        print(f"    Handshake Timeouts: COOKIE_WAIT={res['timeout_cookie_wait']}s | COOKIE_ECHOED={res['timeout_cookie_echoed']}s")
        print(f"    Active Timeouts: ESTABLISHED={res['timeout_established']}s | HEARTBEAT_SENT={res['timeout_heartbeat_sent']}s")
        print(f"    Teardown Timeouts: SHUTDOWN_SENT={res['timeout_shutdown_sent']}s | SHUTDOWN_RECD={res['timeout_shutdown_recd']}s | SHUTDOWN_ACK_SENT={res['timeout_shutdown_ack_sent']}s | CLOSED={res['timeout_closed']}s")
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
