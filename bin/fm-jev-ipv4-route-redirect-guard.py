#!/usr/bin/env python3
"""
bin/fm-jev-ipv4-route-redirect-guard.py - Host Network IPv4 Route Redirect Rate Limiter & Error Token Bucket Guard (Pattern 279 / Pattern 417)

Audits Linux kernel IPv4 route redirect rate limiting and error token bucket parameters:
  - /proc/sys/net/ipv4/route/redirect_load:
      Load factor for ICMP redirect emission (default 20 = 1/5th second).
  - /proc/sys/net/ipv4/route/redirect_number:
      Max consecutive ICMP redirects before entering silence (default 9).
  - /proc/sys/net/ipv4/route/redirect_silence:
      Silence duration in milliseconds before redirect resumption (default 20,480 ms = ~20.5s).
  - /proc/sys/net/ipv4/route/error_cost:
      Token refill period for ICMP error generation in milliseconds (default 1000 ms).
  - /proc/sys/net/ipv4/route/error_burst:
      Maximum burst of ICMP errors allowed before rate limiting (default 5000 ms).
  - /proc/sys/net/ipv4/route/gc_timeout:
      Routing table garbage collector entry timeout (default 300s).
  - /proc/sys/net/ipv4/route/gc_interval:
      Periodic garbage collection sweep interval (default 60s).
  - /proc/sys/net/ipv4/route/gc_min_interval_ms:
      Minimum interval between GC sweeps in milliseconds (default 500 ms).
  - /proc/net/snmp:
      ICMP redirect telemetry (InRedirects, OutRedirects, OutRateLimitGlobal, OutRateLimitHost).

Invariants:
  - redirect_number between 1 and 50.
  - redirect_silence between 1000ms and 120000ms.
  - error_cost > 0.
  - error_burst >= error_cost.
  - gc_timeout >= 10s.
  - gc_interval >= 5s.
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

PROC_ROUTE_DIR = "/proc/sys/net/ipv4/route"
PROC_SNMP = "/proc/net/snmp"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content else default
    except (ValueError, OSError, IndexError):
        return default


def parse_icmp_snmp(path: str) -> Dict[str, int]:
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("Icmp:") and lines[i + 1].startswith("Icmp:"):
                headers = lines[i].split()[1:]
                values = lines[i + 1].split()[1:]
                res = {}
                for h, v in zip(headers, values):
                    try:
                        res[h] = int(v)
                    except ValueError:
                        pass
                return res
        return {}
    except Exception:
        return {}


def audit_ipv4_route_redirect_guard(
    route_dir: str = PROC_ROUTE_DIR,
    snmp_file: str = PROC_SNMP,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    if not os.path.isdir(route_dir):
        return {
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "status": "UNKNOWN",
            "healthy": True,
            "route_dir": route_dir,
            "error": "IPv4 route sysctl directory not found",
            "issues": [],
            "recommendations": [],
        }

    redirect_load = read_sysctl_int(os.path.join(route_dir, "redirect_load"), 20)
    redirect_number = read_sysctl_int(os.path.join(route_dir, "redirect_number"), 9)
    redirect_silence = read_sysctl_int(os.path.join(route_dir, "redirect_silence"), 20480)
    error_cost = read_sysctl_int(os.path.join(route_dir, "error_cost"), 1000)
    error_burst = read_sysctl_int(os.path.join(route_dir, "error_burst"), 5000)
    gc_timeout = read_sysctl_int(os.path.join(route_dir, "gc_timeout"), 300)
    gc_interval = read_sysctl_int(os.path.join(route_dir, "gc_interval"), 60)
    gc_min_interval_ms = read_sysctl_int(os.path.join(route_dir, "gc_min_interval_ms"), 500)

    icmp_stats = parse_icmp_snmp(snmp_file)
    in_redirects = icmp_stats.get("InRedirects", 0)
    out_redirects = icmp_stats.get("OutRedirects", 0)
    out_ratelimit_global = icmp_stats.get("OutRateLimitGlobal", 0)
    out_ratelimit_host = icmp_stats.get("OutRateLimitHost", 0)
    in_errors = icmp_stats.get("InErrors", 0)
    out_errors = icmp_stats.get("OutErrors", 0)

    if redirect_number < 1 and redirect_number != -1:
        issues.append(f"Abnormally low redirect_number ({redirect_number} < 1); ICMP redirect emission disabled")
        recommendations.append("Restore net.ipv4.route.redirect_number to default 9")
    elif redirect_number > 50:
        issues.append(f"Excessive redirect_number ({redirect_number} > 50) risks ICMP redirect spamming")
        recommendations.append("Reduce net.ipv4.route.redirect_number towards default 9")

    if redirect_silence < 1000 and redirect_silence != -1:
        issues.append(f"Dangerous redirect_silence ({redirect_silence}ms < 1000ms); risks redirect storm under route flapping")
        recommendations.append("Restore net.ipv4.route.redirect_silence to at least 20480ms")
        status = "CRITICAL"
    elif redirect_silence > 120000:
        issues.append(f"Excessive redirect_silence ({redirect_silence}ms > 120000ms); prolonged redirect suppression")
        recommendations.append("Reduce net.ipv4.route.redirect_silence towards default 20480ms")

    if error_cost <= 0 and error_cost != -1:
        issues.append(f"Invalid error_cost ({error_cost}ms <= 0); ICMP error rate limiting disabled")
        recommendations.append("Restore net.ipv4.route.error_cost to default 1000ms")
        status = "CRITICAL"

    if error_burst < error_cost and error_burst != -1 and error_cost != -1:
        issues.append(
            f"error_burst ({error_burst}ms) < error_cost ({error_cost}ms); prevents ICMP error token accumulation"
        )
        recommendations.append("Ensure net.ipv4.route.error_burst >= error_cost (default: 5000ms)")

    if gc_timeout < 10 and gc_timeout != -1:
        issues.append(f"Abnormally short route gc_timeout ({gc_timeout}s < 10s)")
        recommendations.append("Restore net.ipv4.route.gc_timeout to default 300s")

    if gc_interval < 5 and gc_interval != -1:
        issues.append(f"Excessively aggressive route gc_interval ({gc_interval}s < 5s)")
        recommendations.append("Restore net.ipv4.route.gc_interval to default 60s")

    if issues and status == "HEALTHY":
        status = "WARNING"

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": (status == "HEALTHY"),
        "redirect_load": redirect_load,
        "redirect_number": redirect_number,
        "redirect_silence_ms": redirect_silence,
        "error_cost_ms": error_cost,
        "error_burst_ms": error_burst,
        "gc_timeout_sec": gc_timeout,
        "gc_interval_sec": gc_interval,
        "gc_min_interval_ms": gc_min_interval_ms,
        "in_redirects": in_redirects,
        "out_redirects": out_redirects,
        "out_ratelimit_global": out_ratelimit_global,
        "out_ratelimit_host": out_ratelimit_host,
        "in_errors": in_errors,
        "out_errors": out_errors,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IPv4 Route Redirect Rate Limiter & Error Token Bucket Guard (Pattern 279 / Pattern 417)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--route-dir", default=PROC_ROUTE_DIR, help="Path to IPv4 route sysctl directory")
    parser.add_argument("--snmp-file", default=PROC_SNMP, help="Path to /proc/net/snmp")
    args = parser.parse_args()

    res = audit_ipv4_route_redirect_guard(
        route_dir=args.route_dir,
        snmp_file=args.snmp_file,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        status_sym = "✓" if res["healthy"] else "✗"
        print(f"[{status_sym}] IPv4 Route Redirect Guard: {res['status']}")
        print(f"    Redirect Controls: number={res['redirect_number']} | load={res['redirect_load']} | silence={res['redirect_silence_ms']}ms")
        print(f"    Error Token Bucket: cost={res['error_cost_ms']}ms | burst={res['error_burst_ms']}ms")
        print(f"    Garbage Collection: timeout={res['gc_timeout_sec']}s | interval={res['gc_interval_sec']}s | min_interval={res['gc_min_interval_ms']}ms")
        print(f"    ICMP Telemetry: in_redirects={res['in_redirects']} | out_redirects={res['out_redirects']} | in_errors={res['in_errors']} | out_errors={res['out_errors']}")
        print(f"    Rate Limiting: host={res['out_ratelimit_host']} | global={res['out_ratelimit_global']}")
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
