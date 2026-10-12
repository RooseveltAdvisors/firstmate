#!/usr/bin/env python3
"""
bin/fm-jev-nf-conntrack-events-guard.py - Host Network Netfilter Connection Tracking Event Delivery, Flow Accounting & Helper Expectation Security Policy Guard (Pattern 272 / Pattern 410)

Audits Linux kernel Netfilter connection tracking event delivery, accounting, and helper policies:
  - /proc/sys/net/netfilter/nf_conntrack_events:
      Netlink event delivery mode (0=disabled, 1=enabled, 2=auto dynamic ctnetlink delivery).
  - /proc/sys/net/netfilter/nf_conntrack_acct:
      Per-flow packet and byte accounting (0=disabled, 1=enabled).
  - /proc/sys/net/netfilter/nf_conntrack_timestamp:
      Flow start/stop nanosecond timestamping (0=disabled, 1=enabled).
  - /proc/sys/net/netfilter/nf_conntrack_expect_max:
      Maximum helper expectation table capacity (default 4096).
  - /proc/sys/net/netfilter/nf_conntrack_udp_timeout:
      Unidirectional UDP timeout in seconds (default 30).
  - /proc/sys/net/netfilter/nf_conntrack_udp_timeout_stream:
      Bidirectional UDP stream timeout in seconds (default 120).
  - /proc/sys/net/netfilter/nf_conntrack_icmp_timeout:
      ICMP timeout in seconds (default 30).
  - /proc/sys/net/netfilter/nf_conntrack_icmpv6_timeout:
      ICMPv6 timeout in seconds (default 30).
  - /proc/sys/net/netfilter/nf_conntrack_count:
      Current tracked connection count.
  - /proc/sys/net/netfilter/nf_conntrack_max:
      Maximum conntrack table size.

Invariants:
  - events should be 0, 1, or 2 (mode 2 auto dynamic ctnetlink preferred in modern kernels).
  - acct and timestamp should be boolean (0 or 1).
  - expect_max should be > 0 (bounding helper expectation table).
  - udp_timeout <= udp_timeout_stream.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths are missing or restricted.
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


def audit_nf_conntrack_events_guard(
    conf_dir: str = PROC_NETFILTER_DIR,
    warn_saturation_pct: float = 80.0,
    crit_saturation_pct: float = 95.0,
) -> Dict[str, Any]:
    issues: List[str] = []
    status = "HEALTHY"

    events = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_events"), 2)
    acct = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_acct"), 0)
    timestamp = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_timestamp"), 0)
    expect_max = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_expect_max"), 4096)
    udp_timeout = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_udp_timeout"), 30)
    udp_timeout_stream = read_sysctl_int(
        os.path.join(conf_dir, "nf_conntrack_udp_timeout_stream"), 120
    )
    icmp_timeout = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_icmp_timeout"), 30)
    icmpv6_timeout = read_sysctl_int(
        os.path.join(conf_dir, "nf_conntrack_icmpv6_timeout"), 30
    )

    count = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_count"), 0)
    max_entries = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_max"), 262144)

    if events not in (0, 1, 2) and events != -1:
        issues.append(
            f"Invalid Netfilter event delivery configuration (nf_conntrack_events={events})"
        )
        if status != "CRITICAL":
            status = "WARNING"

    if acct not in (0, 1) and acct != -1:
        issues.append(
            f"Invalid Netfilter flow accounting configuration (nf_conntrack_acct={acct})"
        )
        if status != "CRITICAL":
            status = "WARNING"

    if timestamp not in (0, 1) and timestamp != -1:
        issues.append(
            f"Invalid Netfilter flow timestamping configuration (nf_conntrack_timestamp={timestamp})"
        )
        if status != "CRITICAL":
            status = "WARNING"

    if expect_max <= 0 and expect_max != -1:
        issues.append(
            f"Netfilter helper expectation table capacity is unconfigured or zero (nf_conntrack_expect_max={expect_max})"
        )
        status = "CRITICAL"

    if udp_timeout <= 0 and udp_timeout != -1:
        issues.append(
            f"Netfilter UDP timeout is non-positive (nf_conntrack_udp_timeout={udp_timeout})"
        )
        if status != "CRITICAL":
            status = "WARNING"

    if udp_timeout_stream <= 0 and udp_timeout_stream != -1:
        issues.append(
            f"Netfilter UDP stream timeout is non-positive (nf_conntrack_udp_timeout_stream={udp_timeout_stream})"
        )
        if status != "CRITICAL":
            status = "WARNING"

    if (
        udp_timeout > 0
        and udp_timeout_stream > 0
        and udp_timeout > udp_timeout_stream
    ):
        issues.append(
            f"Netfilter UDP timeout ({udp_timeout}s) exceeds stream timeout ({udp_timeout_stream}s)"
        )
        if status != "CRITICAL":
            status = "WARNING"

    if icmp_timeout <= 0 and icmp_timeout != -1:
        issues.append(
            f"Netfilter ICMP timeout is non-positive (nf_conntrack_icmp_timeout={icmp_timeout})"
        )
        if status != "CRITICAL":
            status = "WARNING"

    if icmpv6_timeout <= 0 and icmpv6_timeout != -1:
        issues.append(
            f"Netfilter ICMPv6 timeout is non-positive (nf_conntrack_icmpv6_timeout={icmpv6_timeout})"
        )
        if status != "CRITICAL":
            status = "WARNING"

    saturation_pct = 0.0
    if max_entries > 0 and count >= 0:
        saturation_pct = round((count / max_entries) * 100.0, 3)
        if saturation_pct >= crit_saturation_pct:
            issues.append(
                f"Conntrack table saturation critical: {count}/{max_entries} entries ({saturation_pct}% >= {crit_saturation_pct}%)"
            )
            status = "CRITICAL"
        elif saturation_pct >= warn_saturation_pct:
            issues.append(
                f"Conntrack table saturation elevated: {count}/{max_entries} entries ({saturation_pct}% >= {warn_saturation_pct}%)"
            )
            if status != "CRITICAL":
                status = "WARNING"

    return {
        "pattern": 272,
        "name": "nf_conntrack_events",
        "description": "Host Network Netfilter Connection Tracking Event Delivery, Flow Accounting & Helper Expectation Security Policy Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.timezone.utc and datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "events_mode": events,
        "acct_enabled": (acct == 1),
        "timestamp_enabled": (timestamp == 1),
        "expect_max": expect_max,
        "udp_timeout": udp_timeout,
        "udp_timeout_stream": udp_timeout_stream,
        "icmp_timeout": icmp_timeout,
        "icmpv6_timeout": icmpv6_timeout,
        "conntrack_count": count,
        "conntrack_max": max_entries,
        "saturation_pct": saturation_pct,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network Netfilter Connection Tracking Event Delivery, Flow Accounting & Helper Expectation Security Policy Guard"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results as JSON")
    parser.add_argument(
        "--conf-dir",
        default=PROC_NETFILTER_DIR,
        help="Netfilter sysctl directory (default: /proc/sys/net/netfilter)",
    )
    parser.add_argument(
        "--warn-saturation-pct",
        type=float,
        default=80.0,
        help="Warning threshold for conntrack table saturation percentage (default: 80.0)",
    )
    parser.add_argument(
        "--crit-saturation-pct",
        type=float,
        default=95.0,
        help="Critical threshold for conntrack table saturation percentage (default: 95.0)",
    )
    args = parser.parse_args()

    res = audit_nf_conntrack_events_guard(
        conf_dir=args.conf_dir,
        warn_saturation_pct=args.warn_saturation_pct,
        crit_saturation_pct=args.crit_saturation_pct,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        print(f"Pattern {res['pattern']}: {res['name']} - Status: {res['status']}")
        print(
            f"  events_mode={res['events_mode']}, acct_enabled={res['acct_enabled']}, "
            f"timestamp_enabled={res['timestamp_enabled']}, expect_max={res['expect_max']}"
        )
        print(
            f"  timeouts: udp={res['udp_timeout']}s, udp_stream={res['udp_timeout_stream']}s, "
            f"icmp={res['icmp_timeout']}s, icmpv6={res['icmpv6_timeout']}s"
        )
        print(
            f"  capacity: {res['conntrack_count']}/{res['conntrack_max']} entries ({res['saturation_pct']}%)"
        )
        if res["issues"]:
            print("  Issues:")
            for issue in res["issues"]:
                print(f"    - {issue}")
        else:
            print("  Issues: none (nominal)")

    return 0 if res["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
