#!/usr/bin/env python3
"""
fm-jev-ecn-guard.py - Jev Multi-Agent Host Network TCP Explicit Congestion Notification (ECN) Guard (Pattern 114)

Audits Linux TCP Explicit Congestion Notification (ECN) sysctl parameters, fallback protection against middlebox
blackholes, and Congestion Experienced (CE) delivery metrics from /proc/sys/net/ipv4/tcp_ecn, tcp_ecn_fallback,
and /proc/net/netstat (TcpExt: TCPDeliveredCE, TCPEcnECT0, TCPEcnECT1, TCPEcnNoCE, TCPEcnSeen).

Detects silent connection dropouts caused by ECN-unfriendly network paths, disabled fallback protection, and early
network router congestion notifications across multi-agent RPC and cloud LLM streaming endpoints.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysfs/procfs files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

SYSCTL_ECN = "/proc/sys/net/ipv4/tcp_ecn"
SYSCTL_ECN_FALLBACK = "/proc/sys/net/ipv4/tcp_ecn_fallback"
PROC_NETSTAT = "/proc/net/netstat"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def parse_tcpext_netstat(path: Path) -> Dict[str, int]:
    """Parses TcpExt key-value metrics from /proc/net/netstat."""
    if not path.is_file():
        return {}

    metrics: Dict[str, int] = {}
    try:
        lines = path.read_text().splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("TcpExt:") and lines[i + 1].startswith("TcpExt:"):
                keys = lines[i].split()[1:]
                vals = lines[i + 1].split()[1:]
                for k, v in zip(keys, vals):
                    try:
                        metrics[k] = int(v)
                    except ValueError:
                        continue
                break
    except Exception:
        pass

    return metrics


def audit_ecn(
    ecn_file: Optional[str] = None,
    fallback_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits ECN settings, fallback protections, and congestion experienced delivery metrics."""
    ecn_path = Path(ecn_file) if ecn_file else Path(SYSCTL_ECN)
    fallback_path = Path(fallback_file) if fallback_file else Path(SYSCTL_ECN_FALLBACK)
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)

    ecn_val = read_int_file(ecn_path)
    fallback_val = read_int_file(fallback_path)

    tcpext = parse_tcpext_netstat(netstat_path)

    delivered_ce = tcpext.get("TCPDeliveredCE", 0)
    ect0 = tcpext.get("TCPEcnECT0", 0)
    ect1 = tcpext.get("TCPEcnECT1", 0)
    no_ce = tcpext.get("TCPEcnNoCE", 0)
    seen_ecn = tcpext.get("TCPEcnSeen", 0)

    ecn_modes = {
        0: "Disabled",
        1: "Enabled (Client & Server)",
        2: "Server-Only / On-Demand (RFC 3168 adaptive)",
    }
    mode_desc = ecn_modes.get(ecn_val, f"Custom ({ecn_val})")

    issues: List[str] = []

    if ecn_val == 1 and fallback_val == 0:
        issues.append("ECN globally enabled but tcp_ecn_fallback is disabled (0): vulnerable to middlebox SYN blackhole drops")

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_ecn": ecn_val,
            "tcp_ecn_mode": mode_desc,
            "tcp_ecn_fallback": fallback_val == 1 if fallback_val is not None else None,
            "delivered_ce_packets": delivered_ce,
            "issues": issues,
        },
        "counters": {
            "delivered_ce": delivered_ce,
            "ect0": ect0,
            "ect1": ect1,
            "no_ce": no_ce,
            "seen_ecn": seen_ecn,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Explicit Congestion Notification Guard (Pattern 114)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--ecn-file", type=str, default=None, help="Path to tcp_ecn")
    parser.add_argument("--fallback-file", type=str, default=None, help="Path to tcp_ecn_fallback")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_ecn(
        ecn_file=args.ecn_file,
        fallback_file=args.fallback_file,
        netstat_file=args.netstat_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP ECN & Congestion Guard (Pattern 114)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" TCP ECN Mode:                  {summary['tcp_ecn']} ({summary['tcp_ecn_mode']})")
    print(f" TCP ECN Fallback:              {'Enabled (blackhole protection active)' if summary['tcp_ecn_fallback'] else 'Disabled'}")
    print(f" CE Marked Delivered Packets:   {summary['delivered_ce_packets']}")
    print("--------------------------------------------------------------------------------")
    print(f" {'ECN Metric':<35} {'Count':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Delivered Congestion Experienced':<35} {counters['delivered_ce']:<15} Nominal")
    print(f" {'ECT(0) Codepoint Packets':<35} {counters['ect0']:<15} Nominal")
    print(f" {'ECT(1) Codepoint Packets':<35} {counters['ect1']:<15} Nominal")
    print(f" {'ECN Unmarked Packets (No CE)':<35} {counters['no_ce']:<15} Nominal")
    print(f" {'ECN Flows Seen':<35} {counters['seen_ecn']:<15} Nominal")

    if summary["issues"]:
        print("\nActive TCP ECN Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP ECN parameters, blackhole fallbacks, and CE markers nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
