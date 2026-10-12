#!/usr/bin/env python3
"""
bin/fm-jev-nf-flowtable-guard.py - Host Network Netfilter Flowtable Offload & Generic/GRE Timeouts Guard (Pattern 277 / Pattern 415)

Audits Linux kernel Netfilter fast-path flowtable offload and non-TCP/UDP protocol lifetimes:
  - /proc/sys/net/netfilter/nf_flowtable_tcp_timeout:
      Flowtable software/hardware offload TCP idle expiry (default 30s).
  - /proc/sys/net/netfilter/nf_flowtable_udp_timeout:
      Flowtable software/hardware offload UDP idle expiry (default 30s).
  - /proc/sys/net/netfilter/nf_conntrack_generic_timeout:
      Timeout for unrecognized L4 protocols without helper (default 600s).
  - /proc/sys/net/netfilter/nf_conntrack_gre_timeout:
      Single-packet unreplied GRE tunnel tracking timeout (default 30s).
  - /proc/sys/net/netfilter/nf_conntrack_gre_timeout_stream:
      Bidirectional active GRE tunnel tracking timeout (default 180s).
  - /proc/sys/net/netfilter/nf_conntrack_count / nf_conntrack_max:
      Table saturation calculation.

Invariants:
  - flowtable TCP/UDP timeouts between 5s and 300s.
  - generic_timeout between 30s and 3600s.
  - gre_timeout <= gre_timeout_stream.
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


def audit_nf_flowtable_guard(
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

    flowtable_tcp = read_sysctl_int(os.path.join(conf_dir, "nf_flowtable_tcp_timeout"), 30)
    flowtable_udp = read_sysctl_int(os.path.join(conf_dir, "nf_flowtable_udp_timeout"), 30)
    generic_timeout = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_generic_timeout"), 600)
    gre_timeout = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_gre_timeout"), 30)
    gre_stream = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_gre_timeout_stream"), 180)

    conntrack_count = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_count"), 0)
    conntrack_max = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_max"), 262144)

    saturation_pct = 0.0
    if conntrack_max > 0:
        saturation_pct = round((conntrack_count / conntrack_max) * 100.0, 3)

    if flowtable_tcp > 300:
        issues.append(f"Excessive flowtable TCP timeout ({flowtable_tcp}s > 300s); delays offload table cleanup")
        recommendations.append("Reduce nf_flowtable_tcp_timeout to 30s")
    elif flowtable_tcp < 5 and flowtable_tcp != -1:
        issues.append(f"Low flowtable TCP timeout ({flowtable_tcp}s < 5s); risks premature flowtable eviction")
        recommendations.append("Restore nf_flowtable_tcp_timeout to 30s")

    if flowtable_udp > 300:
        issues.append(f"Excessive flowtable UDP timeout ({flowtable_udp}s > 300s); delays offload table cleanup")
        recommendations.append("Reduce nf_flowtable_udp_timeout to 30s")
    elif flowtable_udp < 5 and flowtable_udp != -1:
        issues.append(f"Low flowtable UDP timeout ({flowtable_udp}s < 5s); risks premature flowtable eviction")
        recommendations.append("Restore nf_flowtable_udp_timeout to 30s")

    if generic_timeout > 3600:
        issues.append(f"Excessive generic protocol conntrack timeout ({generic_timeout}s > 3600s)")
        recommendations.append("Reduce nf_conntrack_generic_timeout to 600s")
    elif generic_timeout < 30 and generic_timeout != -1:
        issues.append(f"Low generic protocol conntrack timeout ({generic_timeout}s < 30s)")
        recommendations.append("Increase nf_conntrack_generic_timeout to 600s")

    if gre_timeout > gre_stream and gre_timeout != -1 and gre_stream != -1:
        issues.append(
            f"Inverted GRE timeout hierarchy: unreplied timeout ({gre_timeout}s) > stream timeout ({gre_stream}s)"
        )
        recommendations.append("Ensure nf_conntrack_gre_timeout <= nf_conntrack_gre_timeout_stream")

    if saturation_pct >= crit_saturation_pct:
        issues.append(f"Critical conntrack table saturation: {saturation_pct}% ({conntrack_count}/{conntrack_max})")
        recommendations.append("Tune conntrack flowtable timeouts down or increase nf_conntrack_max")
        status = "CRITICAL"
    elif saturation_pct >= warn_saturation_pct:
        issues.append(f"High conntrack table saturation: {saturation_pct}% ({conntrack_count}/{conntrack_max})")
        recommendations.append("Monitor active protocol flows and tune flowtable eviction timers")
        if status != "CRITICAL":
            status = "WARNING"

    if issues and status == "HEALTHY":
        status = "WARNING"

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": (status == "HEALTHY"),
        "flowtable_tcp_timeout_sec": flowtable_tcp,
        "flowtable_udp_timeout_sec": flowtable_udp,
        "generic_timeout_sec": generic_timeout,
        "gre_timeout_sec": gre_timeout,
        "gre_timeout_stream_sec": gre_stream,
        "conntrack_count": conntrack_count,
        "conntrack_max": conntrack_max,
        "table_saturation_pct": saturation_pct,
        "gre_stream_hierarchy_ok": (gre_timeout <= gre_stream),
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network Netfilter Flowtable Offload & Generic/GRE Timeouts Guard (Pattern 277 / Pattern 415)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--conf-dir", default=PROC_NETFILTER_DIR, help="Path to netfilter sysctl directory")
    parser.add_argument("--warn-saturation", type=float, default=75.0, help="Warning threshold for table saturation pct")
    parser.add_argument("--crit-saturation", type=float, default=90.0, help="Critical threshold for table saturation pct")
    args = parser.parse_args()

    res = audit_nf_flowtable_guard(
        conf_dir=args.conf_dir,
        warn_saturation_pct=args.warn_saturation,
        crit_saturation_pct=args.crit_saturation,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        status_sym = "✓" if res["healthy"] else "✗"
        print(f"[{status_sym}] Netfilter Flowtable Guard: {res['status']}")
        print(f"    Flowtable Timeouts: TCP={res['flowtable_tcp_timeout_sec']}s | UDP={res['flowtable_udp_timeout_sec']}s")
        print(f"    Generic L4 Timeout: {res['generic_timeout_sec']}s")
        print(f"    GRE Tunnel Timeouts: Single={res['gre_timeout_sec']}s | Stream={res['gre_timeout_stream_sec']}s (hierarchy ok: {res['gre_stream_hierarchy_ok']})")
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
