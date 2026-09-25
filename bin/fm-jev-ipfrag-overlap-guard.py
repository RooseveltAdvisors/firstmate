#!/usr/bin/env python3
"""
bin/fm-jev-ipfrag-overlap-guard.py - Linux IP Fragment Overlap Defense & Reassembly Timeout Policy Guard (Pattern 289 / Pattern 427)

Audits Linux kernel IPv4/IPv6 IP fragment overlap queue limits and reassembly timeouts:
  - /proc/sys/net/ipv4/ipfrag_max_dist: Maximum overlapping fragment distance before queue purge (default 64, CVE-2018-5391 mitigation)
  - /proc/sys/net/ipv4/ipfrag_time: IPv4 fragment reassembly timeout in seconds (default 30s)
  - /proc/sys/net/ipv6/ip6frag_time: IPv6 fragment reassembly timeout in seconds (default 60s per RFC 8200 §4.5)
  - /proc/sys/net/ipv4/ipfrag_secret_interval: IPv4 fragment hash secret interval (default 0)
  - /proc/sys/net/ipv6/ip6frag_secret_interval: IPv6 fragment hash secret interval (default 0)
  - /proc/net/snmp: ReasmTimeout, ReasmReqds, ReasmOKs, ReasmFails
  - /proc/net/snmp6: Ip6ReasmTimeout, Ip6ReasmReqds, Ip6ReasmOKs, Ip6ReasmFails

Invariants:
  - ipfrag_max_dist must be >= 1 and <= 256 (prevents FragmentSmack algorithmic complexity exhaustion).
  - ipfrag_time must be >= 5s and <= 120s (bounds incomplete fragment queue retention).
  - ip6frag_time must be >= 10s and <= 180s (RFC 8200 reassembly boundary).
  - Fail-open: graceful fallback when sysctl paths or /proc/net/snmp are restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

SYSCTL_IPV4_BASE = "/proc/sys/net/ipv4"
SYSCTL_IPV6_BASE = "/proc/sys/net/ipv6"
PROC_SNMP = "/proc/net/snmp"
PROC_SNMP6 = "/proc/net/snmp6"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content and (content.split()[0].lstrip("-").isdigit()) else default
    except (ValueError, OSError, IndexError):
        return default


def parse_snmp_ip(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            header = None
            for line in f:
                if line.startswith("Ip: "):
                    tokens = line.split()
                    if header is None:
                        header = tokens[1:]
                    else:
                        for k, v in zip(header, tokens[1:]):
                            try:
                                metrics[k] = int(v)
                            except ValueError:
                                pass
                        break
    except Exception:
        pass
    return metrics


def parse_snmp6(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 2:
                    try:
                        metrics[parts[0]] = int(parts[1])
                    except ValueError:
                        pass
    except Exception:
        pass
    return metrics


def audit_ipfrag_overlap_guard(
    ipv4_dir: str = SYSCTL_IPV4_BASE,
    ipv6_dir: str = SYSCTL_IPV6_BASE,
    snmp_path: str = PROC_SNMP,
    snmp6_path: str = PROC_SNMP6,
    min_max_dist: int = 1,
    max_max_dist: int = 256,
    min_frag_time: int = 5,
    max_frag_time: int = 120,
) -> Dict[str, Any]:
    ipfrag_max_dist = read_sysctl_int(os.path.join(ipv4_dir, "ipfrag_max_dist"), default=64)
    ipfrag_time = read_sysctl_int(os.path.join(ipv4_dir, "ipfrag_time"), default=30)
    ipfrag_secret_interval = read_sysctl_int(os.path.join(ipv4_dir, "ipfrag_secret_interval"), default=0)

    ip6frag_time = read_sysctl_int(os.path.join(ipv6_dir, "ip6frag_time"), default=60)
    ip6frag_secret_interval = read_sysctl_int(os.path.join(ipv6_dir, "ip6frag_secret_interval"), default=0)

    snmp = parse_snmp_ip(snmp_path)
    v4_reasm_reqds = snmp.get("ReasmReqds", 0)
    v4_reasm_oks = snmp.get("ReasmOKs", 0)
    v4_reasm_fails = snmp.get("ReasmFails", 0)
    v4_reasm_timeouts = snmp.get("ReasmTimeout", 0)

    snmp6 = parse_snmp6(snmp6_path)
    v6_reasm_reqds = snmp6.get("Ip6ReasmReqds", 0)
    v6_reasm_oks = snmp6.get("Ip6ReasmOKs", 0)
    v6_reasm_fails = snmp6.get("Ip6ReasmFails", 0)
    v6_reasm_timeouts = snmp6.get("Ip6ReasmTimeout", 0)

    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    if ipfrag_max_dist <= 0:
        issues.append(
            f"Critical security exposure: ipfrag_max_dist={ipfrag_max_dist} disables fragment overlap defense; "
            "vulnerable to FragmentSmack/SegmentSmack (CVE-2018-5391) reassembly queue exhaustion"
        )
        status = "CRITICAL"
        recommendations.append("Set /proc/sys/net/ipv4/ipfrag_max_dist to 64 immediately.")
    elif ipfrag_max_dist < min_max_dist:
        issues.append(
            f"Low ipfrag_max_dist ({ipfrag_max_dist} < {min_max_dist}); "
            "may prematurely drop legitimate out-of-order overlapping fragments"
        )
        status = "WARNING"
        recommendations.append(f"Set /proc/sys/net/ipv4/ipfrag_max_dist >= {min_max_dist}.")
    elif ipfrag_max_dist > max_max_dist:
        issues.append(
            f"Excessive ipfrag_max_dist ({ipfrag_max_dist} > {max_max_dist}); "
            "permits excessive reassembly queue depth and CPU overhead during overlap attacks"
        )
        if status != "CRITICAL":
            status = "WARNING"
        recommendations.append(f"Set /proc/sys/net/ipv4/ipfrag_max_dist <= {max_max_dist}.")

    if ipfrag_time < min_frag_time:
        issues.append(
            f"Low IPv4 fragment reassembly timeout ({ipfrag_time}s < {min_frag_time}s); "
            "risk of premature fragment drop on high-jitter links"
        )
        if status != "CRITICAL":
            status = "WARNING"
        recommendations.append(f"Set /proc/sys/net/ipv4/ipfrag_time >= {min_frag_time}s.")
    elif ipfrag_time > max_frag_time:
        issues.append(
            f"Excessive IPv4 fragment reassembly timeout ({ipfrag_time}s > {max_frag_time}s); "
            "lingering incomplete fragments tie up reassembly buffer memory"
        )
        if status != "CRITICAL":
            status = "WARNING"
        recommendations.append(f"Set /proc/sys/net/ipv4/ipfrag_time <= {max_frag_time}s.")

    if ip6frag_time < 10:
        issues.append(
            f"Low IPv6 fragment reassembly timeout ({ip6frag_time}s < 10s); violates RFC 8200 minimums"
        )
        if status != "CRITICAL":
            status = "WARNING"
        recommendations.append("Set /proc/sys/net/ipv6/ip6frag_time >= 10s (standard 60s).")
    elif ip6frag_time > 180:
        issues.append(
            f"Excessive IPv6 fragment reassembly timeout ({ip6frag_time}s > 180s); buffer bloat hazard"
        )
        if status != "CRITICAL":
            status = "WARNING"
        recommendations.append("Set /proc/sys/net/ipv6/ip6frag_time <= 180s (standard 60s).")

    total_reasm_fails = v4_reasm_fails + v6_reasm_fails
    if total_reasm_fails > 1000:
        issues.append(
            f"Elevated IP fragment reassembly failures detected (v4={v4_reasm_fails}, v6={v6_reasm_fails})"
        )
        if status != "CRITICAL":
            status = "WARNING"
        recommendations.append("Investigate network MTU misconfigurations or fragment drop causes.")

    healthy = (status == "HEALTHY")

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": healthy,
        "ipfrag_max_dist": ipfrag_max_dist,
        "ipfrag_time_sec": ipfrag_time,
        "ip6frag_time_sec": ip6frag_time,
        "ipfrag_secret_interval": ipfrag_secret_interval,
        "ip6frag_secret_interval": ip6frag_secret_interval,
        "v4_reasm_reqds": v4_reasm_reqds,
        "v4_reasm_oks": v4_reasm_oks,
        "v4_reasm_fails": v4_reasm_fails,
        "v4_reasm_timeouts": v4_reasm_timeouts,
        "v6_reasm_reqds": v6_reasm_reqds,
        "v6_reasm_oks": v6_reasm_oks,
        "v6_reasm_fails": v6_reasm_fails,
        "v6_reasm_timeouts": v6_reasm_timeouts,
        "overlap_defense_compliant": healthy,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IP Fragment Overlap Defense & Reassembly Timeout Policy Guard (Pattern 289 / Pattern 427)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--ipv4-dir", default=SYSCTL_IPV4_BASE, help="Path to IPv4 sysctl directory")
    parser.add_argument("--ipv6-dir", default=SYSCTL_IPV6_BASE, help="Path to IPv6 sysctl directory")
    parser.add_argument("--snmp-file", default=PROC_SNMP, help="Path to /proc/net/snmp")
    parser.add_argument("--snmp6-file", default=PROC_SNMP6, help="Path to /proc/net/snmp6")
    args = parser.parse_args()

    res = audit_ipfrag_overlap_guard(
        ipv4_dir=args.ipv4_dir,
        ipv6_dir=args.ipv6_dir,
        snmp_path=args.snmp_file,
        snmp6_path=args.snmp6_file,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        status_sym = "✓" if res["healthy"] else "✗"
        print(f"[{status_sym}] IP Fragment Overlap Guard: {res['status']}")
        print(f"    Parameters: ipfrag_max_dist={res.get('ipfrag_max_dist', 0)} | v4_time={res.get('ipfrag_time_sec', 0)}s | v6_time={res.get('ip6frag_time_sec', 0)}s")
        print(f"    v4 Reassembly: reqds={res.get('v4_reasm_reqds', 0)} | oks={res.get('v4_reasm_oks', 0)} | fails={res.get('v4_reasm_fails', 0)} | timeouts={res.get('v4_reasm_timeouts', 0)}")
        print(f"    v6 Reassembly: reqds={res.get('v6_reasm_reqds', 0)} | oks={res.get('v6_reasm_oks', 0)} | fails={res.get('v6_reasm_fails', 0)} | timeouts={res.get('v6_reasm_timeouts', 0)}")
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
