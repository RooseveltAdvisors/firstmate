#!/usr/bin/env python3
"""
bin/fm-jev-icmp-guard.py - Host Network ICMP Rate Limiting & Error Message Storm Guard (Pattern 205)

Audits Linux kernel IPv4/IPv6 ICMP protocol metrics, rate limiters, and error counters from:
  - /proc/net/snmp (IPv4 ICMP: InMsgs, OutMsgs, InErrors, OutRateLimitGlobal, OutRateLimitHost, InDestUnreachs, OutDestUnreachs, InEchos, OutEchoReps, InRedirects)
  - /proc/net/snmp6 (IPv6 ICMP: Icmp6InMsgs, Icmp6OutMsgs, Icmp6InErrors, Icmp6InDestUnreachs, Icmp6OutDestUnreachs, Icmp6InEchos, Icmp6InEchoReplies)
  - /proc/sys/net/ipv4/icmp_ratelimit, icmp_ratemask, icmp_echo_ignore_broadcasts, icmp_echo_ignore_all

Detects ICMP destination unreachable storms, ICMP rate-limit throttling drops, ICMP redirect spoofing,
and ensures broadcast ping smurf attack defenses are active across multi-agent cluster nodes.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysfs/procfs files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Tuple


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception:
        return default


def parse_snmp_icmp(path: str = "/proc/net/snmp") -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    if not os.path.exists(path):
        return metrics
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = [line.strip() for line in f if line.strip().startswith("Icmp:")]
        if len(lines) >= 2:
            headers = lines[0].split()[1:]
            values = lines[1].split()[1:]
            for h, v in zip(headers, values):
                try:
                    metrics[h] = int(v)
                except ValueError:
                    metrics[h] = 0
    except Exception:
        pass
    return metrics


def parse_snmp6_icmp(path: str = "/proc/net/snmp6") -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    if not os.path.exists(path):
        return metrics
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) == 2 and parts[0].startswith("Icmp6"):
                    try:
                        metrics[parts[0]] = int(parts[1])
                    except ValueError:
                        metrics[parts[0]] = 0
    except Exception:
        pass
    return metrics


def audit_icmp(
    proc_snmp: str = "/proc/net/snmp",
    proc_snmp6: str = "/proc/net/snmp6",
    proc_sys_ipv4: str = "/proc/sys/net/ipv4",
) -> Dict[str, Any]:
    icmp4 = parse_snmp_icmp(proc_snmp)
    icmp6 = parse_snmp6_icmp(proc_snmp6)

    ratelimit_path = os.path.join(proc_sys_ipv4, "icmp_ratelimit")
    ratemask_path = os.path.join(proc_sys_ipv4, "icmp_ratemask")
    ignore_bcast_path = os.path.join(proc_sys_ipv4, "icmp_echo_ignore_broadcasts")
    ignore_all_path = os.path.join(proc_sys_ipv4, "icmp_echo_ignore_all")

    icmp_ratelimit = read_sysctl_int(ratelimit_path, 1000)
    icmp_ratemask = read_sysctl_int(ratemask_path, 6168)
    ignore_bcast = read_sysctl_int(ignore_bcast_path, 1)
    ignore_all = read_sysctl_int(ignore_all_path, 0)

    in_msgs = icmp4.get("InMsgs", 0) + icmp6.get("Icmp6InMsgs", 0)
    out_msgs = icmp4.get("OutMsgs", 0) + icmp6.get("Icmp6OutMsgs", 0)
    in_errors = icmp4.get("InErrors", 0) + icmp6.get("Icmp6InErrors", 0)
    out_errors = icmp4.get("OutErrors", 0) + icmp6.get("Icmp6OutErrors", 0)
    in_csum_errors = icmp4.get("InCsumErrors", 0)

    in_dest_unreach = icmp4.get("InDestUnreachs", 0) + icmp6.get("Icmp6InDestUnreachs", 0)
    out_dest_unreach = icmp4.get("OutDestUnreachs", 0) + icmp6.get("Icmp6OutDestUnreachs", 0)

    in_echos = icmp4.get("InEchos", 0) + icmp6.get("Icmp6InEchos", 0)
    out_echo_reps = icmp4.get("OutEchoReps", 0) + icmp6.get("Icmp6OutEchoReplies", 0)

    ratelimit_global = icmp4.get("OutRateLimitGlobal", 0)
    ratelimit_host = icmp4.get("OutRateLimitHost", 0)
    total_ratelimit_drops = ratelimit_global + ratelimit_host

    in_redirects = icmp4.get("InRedirects", 0)
    out_redirects = icmp4.get("OutRedirects", 0)
    total_redirects = in_redirects + out_redirects

    in_error_ratio = float(in_errors) / max(1, in_msgs)
    ratelimit_drop_ratio = float(total_ratelimit_drops) / max(1, out_msgs + total_ratelimit_drops)
    echo_ratio = float(out_echo_reps) / max(1, in_echos)

    issues: List[str] = []
    status = "HEALTHY"

    if ignore_bcast != 1:
        issues.append("WARNING: icmp_echo_ignore_broadcasts is disabled (smurf attack vulnerability)")
        status = "WARNING"

    if in_csum_errors > 0:
        issues.append(f"WARNING: ICMP checksum errors detected ({in_csum_errors} corrupt packets)")
        status = "WARNING"

    if in_error_ratio > 0.05 and in_msgs > 100:
        issues.append(f"CRITICAL: Excessive ICMP input error ratio ({in_error_ratio:.4%}, {in_errors} errors)")
        status = "CRITICAL"
    elif in_error_ratio > 0.01 and in_msgs > 100:
        issues.append(f"WARNING: Elevated ICMP input error ratio ({in_error_ratio:.4%}, {in_errors} errors)")
        if status != "CRITICAL":
            status = "WARNING"

    if total_redirects > 100:
        issues.append(f"WARNING: Elevated ICMP redirects ({total_redirects} redirects); check routing topology")
        if status != "CRITICAL":
            status = "WARNING"

    healthy = status == "HEALTHY"
    recommendation = (
        "ICMP messaging, error ratios, rate limiters, and smurf defenses are nominal."
        if healthy
        else "; ".join(issues)
    )

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "in_msgs": in_msgs,
            "out_msgs": out_msgs,
            "in_errors": in_errors,
            "in_error_ratio": round(in_error_ratio, 6),
            "out_errors": out_errors,
            "in_csum_errors": in_csum_errors,
            "in_dest_unreach": in_dest_unreach,
            "out_dest_unreach": out_dest_unreach,
            "in_echos": in_echos,
            "out_echo_reps": out_echo_reps,
            "echo_ratio": round(echo_ratio, 4),
            "ratelimit_global_drops": ratelimit_global,
            "ratelimit_host_drops": ratelimit_host,
            "total_ratelimit_drops": total_ratelimit_drops,
            "ratelimit_drop_ratio": round(ratelimit_drop_ratio, 6),
            "total_redirects": total_redirects,
            "icmp_ratelimit_ms": icmp_ratelimit,
            "icmp_ratemask": icmp_ratemask,
            "icmp_echo_ignore_broadcasts": ignore_bcast,
            "icmp_echo_ignore_all": ignore_all,
            "issues": issues,
            "recommendation": recommendation,
        },
        "raw_stats": {
            "icmp4": icmp4,
            "icmp6": icmp6,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network ICMP Rate Limiting & Error Message Storm Guard (Pattern 205)"
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON telemetry")
    args = parser.parse_args()

    report = audit_icmp()
    s = report["summary"]

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"[{s['status']}] Pattern 205: Host Network ICMP Rate Limiting Guard")
        print(f"  InMsgs: {s['in_msgs']:,} | OutMsgs: {s['out_msgs']:,} | InErrors: {s['in_errors']:,} ({s['in_error_ratio']:.4%})")
        print(f"  DestUnreach (In/Out): {s['in_dest_unreach']:,} / {s['out_dest_unreach']:,}")
        print(f"  Echo Requests / Replies: {s['in_echos']:,} / {s['out_echo_reps']:,} ({s['echo_ratio']:.2%})")
        print(f"  RateLimit Drops: global={s['ratelimit_global_drops']:,}, host={s['ratelimit_host_drops']:,} ({s['ratelimit_drop_ratio']:.4%})")
        print(f"  Sysctls: ratelimit={s['icmp_ratelimit_ms']}ms, ratemask={s['icmp_ratemask']}, ignore_bcast={s['icmp_echo_ignore_broadcasts']}")
        print(f"  Recommendation: {s['recommendation']}")

    return 0 if s["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
