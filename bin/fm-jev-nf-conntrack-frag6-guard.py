#!/usr/bin/env python3
"""
bin/fm-jev-nf-conntrack-frag6-guard.py - Host Network Netfilter IPv6 Fragment Reassembly Queue & Memory Policy Guard (Pattern 273 / Pattern 411)

Audits Linux kernel Netfilter IPv6 connection tracking fragment reassembly queue thresholds:
  - /proc/sys/net/netfilter/nf_conntrack_frag6_high_thresh:
      High watermark memory limit for IPv6 fragments (default 4194304 bytes = 4MB).
  - /proc/sys/net/netfilter/nf_conntrack_frag6_low_thresh:
      Low watermark memory limit for IPv6 fragments (default 3145728 bytes = 3MB).
  - /proc/sys/net/netfilter/nf_conntrack_frag6_timeout:
      Fragment reassembly timeout in seconds (default 60s, RFC 8200 compliant).
  - /proc/net/sockstat6:
      FRAG6 inuse count and memory bytes.
  - /proc/net/snmp6:
      Ip6ReasmReqds, Ip6ReasmOKs, Ip6ReasmFails, Ip6ReasmTimeout.

Invariants:
  - high_thresh > 0 and low_thresh > 0.
  - low_thresh < high_thresh (hysteresis preserved).
  - timeout == 60 (RFC 8200 compliant).
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
PROC_SOCKSTAT6 = "/proc/net/sockstat6"
PROC_SNMP6 = "/proc/net/snmp6"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content else default
    except (ValueError, OSError, IndexError):
        return default


def parse_sockstat6_frag(path: str) -> Dict[str, int]:
    metrics = {"frag6_inuse": 0, "frag6_memory": 0}
    if not os.path.isfile(path):
        return metrics
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        for line in lines:
            if line.startswith("FRAG6:"):
                parts = line.split()
                for i in range(len(parts) - 1):
                    if parts[i] == "inuse":
                        try:
                            metrics["frag6_inuse"] = int(parts[i + 1])
                        except ValueError:
                            pass
                    elif parts[i] == "memory":
                        try:
                            metrics["frag6_memory"] = int(parts[i + 1])
                        except ValueError:
                            pass
    except Exception:
        pass
    return metrics


def parse_snmp6_reasm(path: str) -> Dict[str, int]:
    metrics = {
        "Ip6ReasmTimeout": 0,
        "Ip6ReasmReqds": 0,
        "Ip6ReasmOKs": 0,
        "Ip6ReasmFails": 0,
    }
    if not os.path.isfile(path):
        return metrics
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        for line in lines:
            parts = line.split()
            if len(parts) >= 2 and parts[0] in metrics:
                try:
                    metrics[parts[0]] = int(parts[1])
                except ValueError:
                    pass
    except Exception:
        pass
    return metrics


def audit_nf_conntrack_frag6_guard(
    conf_dir: str = PROC_NETFILTER_DIR,
    sockstat6_file: str = PROC_SOCKSTAT6,
    snmp6_file: str = PROC_SNMP6,
    warn_saturation_pct: float = 75.0,
    crit_saturation_pct: float = 90.0,
) -> Dict[str, Any]:
    issues: List[str] = []
    status = "HEALTHY"

    high_thresh = read_sysctl_int(
        os.path.join(conf_dir, "nf_conntrack_frag6_high_thresh"), 4194304
    )
    low_thresh = read_sysctl_int(
        os.path.join(conf_dir, "nf_conntrack_frag6_low_thresh"), 3145728
    )
    timeout = read_sysctl_int(
        os.path.join(conf_dir, "nf_conntrack_frag6_timeout"), 60
    )

    sockstat = parse_sockstat6_frag(sockstat6_file)
    snmp6 = parse_snmp6_reasm(snmp6_file)

    if high_thresh <= 0 and high_thresh != -1:
        issues.append(
            f"Netfilter IPv6 fragment high threshold is non-positive (nf_conntrack_frag6_high_thresh={high_thresh})"
        )
        status = "CRITICAL"

    if low_thresh <= 0 and low_thresh != -1:
        issues.append(
            f"Netfilter IPv6 fragment low threshold is non-positive (nf_conntrack_frag6_low_thresh={low_thresh})"
        )
        if status != "CRITICAL":
            status = "WARNING"

    if high_thresh > 0 and low_thresh > 0 and low_thresh >= high_thresh:
        issues.append(
            f"Netfilter IPv6 fragment low threshold ({low_thresh} B) >= high threshold ({high_thresh} B); hysteresis broken"
        )
        if status != "CRITICAL":
            status = "WARNING"

    if timeout <= 0 and timeout != -1:
        issues.append(
            f"Netfilter IPv6 fragment reassembly timeout is non-positive (nf_conntrack_frag6_timeout={timeout})"
        )
        if status != "CRITICAL":
            status = "WARNING"
    elif timeout > 120:
        issues.append(
            f"Netfilter IPv6 fragment reassembly timeout elevated ({timeout}s > 120s); risk of queue memory exhaustion"
        )
        if status != "CRITICAL":
            status = "WARNING"

    frag6_mem = sockstat["frag6_memory"]
    frag6_inuse = sockstat["frag6_inuse"]
    saturation_pct = 0.0
    if high_thresh > 0 and frag6_mem >= 0:
        saturation_pct = round((frag6_mem / high_thresh) * 100.0, 3)
        if saturation_pct >= crit_saturation_pct:
            issues.append(
                f"Netfilter IPv6 fragment queue saturation critical: {frag6_mem}/{high_thresh} B ({saturation_pct}% >= {crit_saturation_pct}%)"
            )
            status = "CRITICAL"
        elif saturation_pct >= warn_saturation_pct:
            issues.append(
                f"Netfilter IPv6 fragment queue saturation elevated: {frag6_mem}/{high_thresh} B ({saturation_pct}% >= {warn_saturation_pct}%)"
            )
            if status != "CRITICAL":
                status = "WARNING"

    reqds = snmp6["Ip6ReasmReqds"]
    fails = snmp6["Ip6ReasmFails"]
    if reqds > 100 and fails > 0:
        fail_pct = round((fails / reqds) * 100.0, 2)
        if fail_pct >= 50.0:
            issues.append(
                f"High IPv6 fragment reassembly failure rate: {fails}/{reqds} ({fail_pct}%)"
            )
            if status != "CRITICAL":
                status = "WARNING"

    return {
        "pattern": 273,
        "name": "nf_conntrack_frag6",
        "description": "Host Network Netfilter IPv6 Fragment Reassembly Queue & Memory Policy Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.timezone.utc and datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "frag6_high_thresh_bytes": high_thresh,
        "frag6_low_thresh_bytes": low_thresh,
        "frag6_timeout_sec": timeout,
        "frag6_inuse": frag6_inuse,
        "frag6_memory_bytes": frag6_mem,
        "saturation_pct": saturation_pct,
        "reasm_reqds": reqds,
        "reasm_oks": snmp6["Ip6ReasmOKs"],
        "reasm_fails": fails,
        "reasm_timeout": snmp6["Ip6ReasmTimeout"],
        "rfc8200_compliant": (timeout == 60 and high_thresh >= 4194304),
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network Netfilter IPv6 Fragment Reassembly Queue & Memory Policy Guard"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results as JSON")
    parser.add_argument(
        "--conf-dir",
        default=PROC_NETFILTER_DIR,
        help="Netfilter sysctl directory (default: /proc/sys/net/netfilter)",
    )
    parser.add_argument(
        "--sockstat6-file",
        default=PROC_SOCKSTAT6,
        help="sockstat6 file path (default: /proc/net/sockstat6)",
    )
    parser.add_argument(
        "--snmp6-file",
        default=PROC_SNMP6,
        help="snmp6 file path (default: /proc/net/snmp6)",
    )
    parser.add_argument(
        "--warn-saturation-pct",
        type=float,
        default=75.0,
        help="Warning threshold for fragment memory saturation percentage (default: 75.0)",
    )
    parser.add_argument(
        "--crit-saturation-pct",
        type=float,
        default=90.0,
        help="Critical threshold for fragment memory saturation percentage (default: 90.0)",
    )
    args = parser.parse_args()

    res = audit_nf_conntrack_frag6_guard(
        conf_dir=args.conf_dir,
        sockstat6_file=args.sockstat6_file,
        snmp6_file=args.snmp6_file,
        warn_saturation_pct=args.warn_saturation_pct,
        crit_saturation_pct=args.crit_saturation_pct,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        print(f"Pattern {res['pattern']}: {res['name']} - Status: {res['status']}")
        print(
            f"  high_thresh={res['frag6_high_thresh_bytes']} B, low_thresh={res['frag6_low_thresh_bytes']} B, "
            f"timeout={res['frag6_timeout_sec']}s (rfc8200={res['rfc8200_compliant']})"
        )
        print(
            f"  frag6_inuse={res['frag6_inuse']}, memory={res['frag6_memory_bytes']} B "
            f"({res['saturation_pct']}%), reasm_reqds={res['reasm_reqds']}, reasm_fails={res['reasm_fails']}"
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
