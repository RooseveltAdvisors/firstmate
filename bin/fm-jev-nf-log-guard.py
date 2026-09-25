#!/usr/bin/env python3
"""
bin/fm-jev-nf-log-guard.py - Host Network Netfilter Logging Backends & Multi-Namespace Isolation Guard (Pattern 282 / Pattern 420)

Audits Linux kernel Netfilter protocol logging backend assignments, multi-network namespace logging policy,
and conntrack table bucket sizing:
  - /proc/sys/net/netfilter/nf_log_all_netns:
      Whether non-init netns are permitted to log to host dmesg (default 0).
  - /proc/sys/net/netfilter/nf_log/*:
      Protocol family logging backend assignments (0=unspec, 2=ipv4, 7=bridge, 10=ipv6).
  - /proc/sys/net/netfilter/nf_hooks_lwtunnel:
      Lightweight tunnel netfilter hook execution (default 0).
  - /proc/sys/net/netfilter/nf_conntrack_buckets:
      Hash table bucket count (default 262144).
  - /proc/sys/net/netfilter/nf_conntrack_max:
      Maximum conntrack entries (default 262144).
  - /proc/sys/net/netfilter/nf_conntrack_count:
      Active tracked connections.

Invariants:
  - nf_log_all_netns must remain 0 to prevent container namespaces from flooding host dmesg/syslog.
  - conntrack_max must be >= buckets to prevent hash chain starvation.
  - conntrack table saturation (count / max) must remain < 85%.
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
PROC_NF_LOG_DIR = "/proc/sys/net/netfilter/nf_log"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content and (content.split()[0].lstrip("-").isdigit()) else default
    except (ValueError, OSError, IndexError):
        return default


def read_sysctl_str(path: str, default: str = "") -> str:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except (OSError, IndexError):
        return default


def audit_nf_log_guard(
    conf_dir: str = PROC_NETFILTER_DIR,
    nf_log_dir: str = PROC_NF_LOG_DIR,
    allow_all_netns_logging: bool = False,
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
            "error": f"Netfilter sysctl directory not found at {conf_dir}",
            "issues": [],
            "recommendations": [],
        }

    log_all_netns = read_sysctl_int(os.path.join(conf_dir, "nf_log_all_netns"), 0)
    hooks_lwtunnel = read_sysctl_int(os.path.join(conf_dir, "nf_hooks_lwtunnel"), 0)
    ct_buckets = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_buckets"), 262144)
    ct_max = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_max"), 262144)
    ct_count = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_count"), 0)

    backends: Dict[str, str] = {}
    if os.path.isdir(nf_log_dir):
        try:
            for entry in sorted(os.listdir(nf_log_dir)):
                fpath = os.path.join(nf_log_dir, entry)
                if os.path.isfile(fpath):
                    backends[entry] = read_sysctl_str(fpath, "NONE")
        except Exception:
            pass

    if log_all_netns != 0 and log_all_netns != -1 and not allow_all_netns_logging:
        issues.append(
            f"nf_log_all_netns is enabled ({log_all_netns}): "
            "allows non-init network namespaces to write to host kernel log/dmesg"
        )
        recommendations.append("Set net.netfilter.nf_log_all_netns=0 to isolate container logging from host syslog")
        status = "CRITICAL"

    if ct_buckets > 0 and ct_max > 0:
        ratio = ct_max / ct_buckets
        if ratio > 16.0:
            issues.append(f"Excessive conntrack max to buckets ratio ({ratio:.1f} > 16): risks long hash collision chains")
            recommendations.append("Increase net.netfilter.nf_conntrack_buckets towards nf_conntrack_max / 4")
        elif ct_max < ct_buckets:
            issues.append(f"Abnormal conntrack sizing: max ({ct_max}) < buckets ({ct_buckets})")
            recommendations.append("Ensure net.netfilter.nf_conntrack_max >= nf_conntrack_buckets")

    sat_pct = (ct_count / ct_max * 100.0) if ct_max > 0 and ct_count >= 0 else 0.0
    if sat_pct >= 95.0:
        issues.append(f"Critical conntrack table saturation: {ct_count}/{ct_max} ({sat_pct:.2f}%)")
        recommendations.append("Increase net.netfilter.nf_conntrack_max or inspect connection leak")
        status = "CRITICAL"
    elif sat_pct >= 85.0:
        issues.append(f"Elevated conntrack table saturation: {ct_count}/{ct_max} ({sat_pct:.2f}%)")
        recommendations.append("Monitor conntrack connection count growth")
        if status == "HEALTHY":
            status = "WARNING"

    if issues and status == "HEALTHY":
        status = "WARNING"

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": (status == "HEALTHY"),
        "nf_log_all_netns": log_all_netns,
        "nf_hooks_lwtunnel": hooks_lwtunnel,
        "nf_conntrack_buckets": ct_buckets,
        "nf_conntrack_max": ct_max,
        "nf_conntrack_count": ct_count,
        "conntrack_saturation_pct": round(sat_pct, 3),
        "log_backends_count": len(backends),
        "ipv4_log_backend": backends.get("2", "NONE"),
        "ipv6_log_backend": backends.get("10", "NONE"),
        "log_backends": backends,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network Netfilter Logging Backends & Multi-Namespace Isolation Guard (Pattern 282 / Pattern 420)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--conf-dir", default=PROC_NETFILTER_DIR, help="Path to netfilter sysctl directory")
    parser.add_argument("--nf-log-dir", default=PROC_NF_LOG_DIR, help="Path to nf_log sysctl directory")
    parser.add_argument("--allow-all-netns-logging", action="store_true", help="Allow non-init netns logging to host dmesg")
    args = parser.parse_args()

    res = audit_nf_log_guard(
        conf_dir=args.conf_dir,
        nf_log_dir=args.nf_log_dir,
        allow_all_netns_logging=args.allow_all_netns_logging,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        status_sym = "✓" if res["healthy"] else "✗"
        print(f"[{status_sym}] Netfilter Logging & Isolation Guard: {res['status']}")
        print(f"    Namespace Isolation: nf_log_all_netns={res.get('nf_log_all_netns', 0)} | nf_hooks_lwtunnel={res.get('nf_hooks_lwtunnel', 0)}")
        print(f"    Conntrack Table: {res.get('nf_conntrack_count', 0)}/{res.get('nf_conntrack_max', 0)} ({res.get('conntrack_saturation_pct', 0.0)}%) | buckets={res.get('nf_conntrack_buckets', 0)}")
        print(f"    Logging Backends: count={res.get('log_backends_count', 0)} | ipv4(2)={res.get('ipv4_log_backend', 'NONE')} | ipv6(10)={res.get('ipv6_log_backend', 'NONE')}")
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
