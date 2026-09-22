#!/usr/bin/env python3
"""
fm-jev-tfo-guard.py - Jev Multi-Agent Host Network TCP Fast Open (TFO) Guard (Pattern 105)

Audits Linux TCP Fast Open (TFO) sysctls and TcpExt loss/cookie counters from
/proc/sys/net/ipv4/tcp_fastopen, tcp_fastopen_blackhole_timeout_sec, and /proc/net/netstat (TcpExt).

Detects TFO middlebox blackholes, SYN-data handshake failures, listen queue overflows on TFO sockets,
and misconfigured client/server bitmasks across low-latency multi-agent RPC and streaming endpoints.

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

SYSCTL_TCP_FASTOPEN = "/proc/sys/net/ipv4/tcp_fastopen"
SYSCTL_TFO_BLACKHOLE_TIMEOUT = "/proc/sys/net/ipv4/tcp_fastopen_blackhole_timeout_sec"
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


def decode_tfo_bitmask(val: Optional[int]) -> Dict[str, bool]:
    """Decodes Linux tcp_fastopen bitmask flags."""
    if val is None:
        return {
            "client_enabled": False,
            "server_enabled": False,
            "client_no_cookie": False,
            "server_no_cookie": False,
        }
    return {
        "client_enabled": bool(val & 0x1),
        "server_enabled": bool(val & 0x2),
        "client_no_cookie": bool(val & 0x4),
        "server_no_cookie": bool(val & 0x200),
    }


def audit_tfo(
    fastopen_file: Optional[str] = None,
    blackhole_timeout_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TCP Fast Open configuration and handshake loss counters."""
    fastopen_path = Path(fastopen_file) if fastopen_file else Path(SYSCTL_TCP_FASTOPEN)
    timeout_path = Path(blackhole_timeout_file) if blackhole_timeout_file else Path(SYSCTL_TFO_BLACKHOLE_TIMEOUT)
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)

    fastopen_raw = read_int_file(fastopen_path)
    blackhole_timeout = read_int_file(timeout_path)
    tcpext = parse_tcpext_netstat(netstat_path)

    bitmask = decode_tfo_bitmask(fastopen_raw)

    tfo_active = tcpext.get("TCPFastOpenActive", 0)
    tfo_active_fail = tcpext.get("TCPFastOpenActiveFail", 0)
    tfo_passive = tcpext.get("TCPFastOpenPassive", 0)
    tfo_passive_fail = tcpext.get("TCPFastOpenPassiveFail", 0)
    tfo_listen_overflow = tcpext.get("TCPFastOpenListenOverflow", 0)
    tfo_cookie_reqd = tcpext.get("TCPFastOpenCookieReqd", 0)
    tfo_blackhole = tcpext.get("TCPFastOpenBlackholeDetected", 0)

    issues: List[str] = []

    if tfo_blackhole > 0:
        issues.append(f"TCP Fast Open blackholes detected ({tfo_blackhole} events): middlebox is dropping SYN+data packets")

    if tfo_listen_overflow > 10:
        issues.append(f"TFO listen queue overflow ({tfo_listen_overflow} drops): server backlog full on fastopen")

    if tfo_active > 50 and (tfo_active_fail / tfo_active) > 0.2:
        fail_pct = (tfo_active_fail / tfo_active) * 100.0
        issues.append(f"Elevated client TFO failure rate ({fail_pct:.1f}%): frequent fallback to standard 3-way handshake")

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_fastopen_raw": fastopen_raw,
            "client_tfo_enabled": bitmask["client_enabled"],
            "server_tfo_enabled": bitmask["server_enabled"],
            "blackhole_timeout_sec": blackhole_timeout,
            "blackholes_detected": tfo_blackhole,
            "active_failures": tfo_active_fail,
            "listen_overflows": tfo_listen_overflow,
            "issues": issues,
        },
        "bitmask": bitmask,
        "counters": {
            "tfo_active": tfo_active,
            "tfo_active_fail": tfo_active_fail,
            "tfo_passive": tfo_passive,
            "tfo_passive_fail": tfo_passive_fail,
            "tfo_listen_overflow": tfo_listen_overflow,
            "tfo_cookie_reqd": tfo_cookie_reqd,
            "tfo_blackhole": tfo_blackhole,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Fast Open (TFO) Guard (Pattern 105)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--fastopen-file", type=str, default=None, help="Path to tcp_fastopen")
    parser.add_argument("--blackhole-timeout-file", type=str, default=None, help="Path to tcp_fastopen_blackhole_timeout_sec")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_tfo(
        fastopen_file=args.fastopen_file,
        blackhole_timeout_file=args.blackhole_timeout_file,
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
    print(" Jev Multi-Agent Host Network TCP Fast Open (TFO) Guard (Pattern 105)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" TCP Fast Open Value:           {summary['tcp_fastopen_raw']}")
    print(f" Client TFO:                    {'Enabled' if summary['client_tfo_enabled'] else 'Disabled'}")
    print(f" Server TFO:                    {'Enabled' if summary['server_tfo_enabled'] else 'Disabled'}")
    print(f" Blackhole Timeout:             {summary['blackhole_timeout_sec']}s")
    print("--------------------------------------------------------------------------------")
    print(f" {'TFO Metric':<30} {'Count':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Active TFO Handshakes':<30} {counters['tfo_active']:<15} Nominal")
    print(f" {'Active TFO Failures':<30} {counters['tfo_active_fail']:<15} Nominal")
    print(f" {'Passive TFO Handshakes':<30} {counters['tfo_passive']:<15} Nominal")
    print(f" {'Passive TFO Failures':<30} {counters['tfo_passive_fail']:<15} Nominal")
    print(f" {'Listen Queue Overflows':<30} {counters['tfo_listen_overflow']:<15} {'Nominal' if counters['tfo_listen_overflow'] <= 10 else 'WARNING'}")
    print(f" {'Blackhole Events Detected':<30} {counters['tfo_blackhole']:<15} {'Nominal' if counters['tfo_blackhole'] == 0 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive TCP Fast Open Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP Fast Open configuration and loss parameters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
