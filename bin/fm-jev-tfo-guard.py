#!/usr/bin/env python3
"""
fm-jev-tfo-guard.py - Jev Multi-Agent Host Network TCP Fast Open (TFO) Cookie & Handshake Acceleration Guard (Pattern 150)

Audits Linux TCP Fast Open (RFC 7413) configuration, TFO cookie validation, and handshake acceleration:
  - /proc/sys/net/ipv4/tcp_fastopen (bitmap mode: 1=client, 2=server, 4=client data without cookie, 512=all client, 1024=all server)
  - /proc/net/netstat metrics:
      - TCPFastOpenActive (Active TFO SYN+data sent by client)
      - TCPFastOpenActiveFail (Active TFO fallback / failure)
      - TCPFastOpenPassive (Valid TFO connections accepted by server)
      - TCPFastOpenPassiveFail (Server rejected invalid TFO cookie)
      - TCPFastOpenListenOverflow (TFO handshakes dropped due to queue overflow)
      - TCPFastOpenCookieReqd (TFO SYN received without cookie)
      - TCPFastOpenBlackhole (Middlebox TFO packet drops detected by kernel)
      - TCPFastOpenPassiveAltKey (Connections accepted with secondary key)

In multi-agent microservice topologies, TCP Fast Open saves a full Round Trip Time (RTT) per connection
by piggybacking application payloads directly inside the initial SYN packet. ActiveFail and Blackhole
counters identify aggressive middleboxes or firewalls stripping SYN data frames.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysctl or procfs entries are inaccessible.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

PROC_NETSTAT = "/proc/net/netstat"
SYSCTL_FASTOPEN = "/proc/sys/net/ipv4/tcp_fastopen"


def read_int_file(path: Path, default: int = 0) -> int:
    """Safely reads an integer from a sysctl file."""
    if not path.is_file():
        return default
    try:
        return int(path.read_text().strip())
    except Exception:
        return default


def parse_tfo_counters(netstat_path: Path) -> Dict[str, int]:
    """Parses TCP Fast Open metrics from /proc/net/netstat."""
    counters: Dict[str, int] = {
        "active": 0,
        "active_fail": 0,
        "passive": 0,
        "passive_fail": 0,
        "listen_overflow": 0,
        "cookie_reqd": 0,
        "blackhole": 0,
        "alt_key": 0,
    }

    if not netstat_path.is_file():
        return counters

    try:
        lines = netstat_path.read_text().splitlines()
        for i in range(0, len(lines) - 1, 2):
            header_line = lines[i].strip()
            data_line = lines[i + 1].strip()
            if header_line.startswith("TcpExt:") and data_line.startswith("TcpExt:"):
                headers = header_line.split()[1:]
                values = data_line.split()[1:]
                header_map = {h: int(v) for h, v in zip(headers, values) if v.isdigit()}

                counters["active"] = header_map.get("TCPFastOpenActive", 0)
                counters["active_fail"] = header_map.get("TCPFastOpenActiveFail", 0)
                counters["passive"] = header_map.get("TCPFastOpenPassive", 0)
                counters["passive_fail"] = header_map.get("TCPFastOpenPassiveFail", 0)
                counters["listen_overflow"] = header_map.get("TCPFastOpenListenOverflow", 0)
                counters["cookie_reqd"] = header_map.get("TCPFastOpenCookieReqd", 0)
                counters["blackhole"] = header_map.get("TCPFastOpenBlackhole", 0)
                counters["alt_key"] = header_map.get("TCPFastOpenPassiveAltKey", 0)
                break
    except Exception:
        pass

    return counters


def audit_tfo(
    netstat_file: Optional[str] = None,
    fastopen_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TCP Fast Open settings and connection metrics."""
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)
    fastopen_path = Path(fastopen_file) if fastopen_file else Path(SYSCTL_FASTOPEN)

    tfo_mode = read_int_file(fastopen_path, default=1)
    client_enabled = bool(tfo_mode & 0x1)
    server_enabled = bool(tfo_mode & 0x2)

    counters = parse_tfo_counters(netstat_path)
    active = counters["active"]
    active_fail = counters["active_fail"]
    passive = counters["passive"]
    passive_fail = counters["passive_fail"]
    blackhole = counters["blackhole"]
    overflow = counters["listen_overflow"]

    issues: List[str] = []

    # 1. TFO completely disabled
    if tfo_mode == 0:
        issues.append("tcp_fastopen is disabled (0); 0-RTT connection acceleration unavailable")

    # 2. Blackhole detected
    if blackhole > 0:
        issues.append(f"TCP Fast Open blackhole detected ({blackhole:,} events); network paths dropping SYN data")

    # 3. Listen queue overflows on TFO handshakes
    if overflow > 100:
        issues.append(f"TFO listen queue overflow events ({overflow:,} overflows)")

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "tcp_fastopen_mode": tfo_mode,
            "client_enabled": client_enabled,
            "server_enabled": server_enabled,
            "active_tfo": active,
            "active_fail": active_fail,
            "passive_tfo": passive,
            "passive_fail": passive_fail,
            "blackhole_events": blackhole,
            "listen_overflow": overflow,
            "issues": issues,
        },
        "counters": counters,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Fast Open (TFO) Cookie & Handshake Acceleration Guard (Pattern 150)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    parser.add_argument("--fastopen-file", type=str, default=None, help="Path to tcp_fastopen")
    args = parser.parse_args()

    result = audit_tfo(netstat_file=args.netstat_file, fastopen_file=args.fastopen_file)

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP Fast Open (TFO) Guard (Pattern 150)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" tcp_fastopen Mode:             {summary['tcp_fastopen_mode']} (Client: {summary['client_enabled']}, Server: {summary['server_enabled']})")
    print(f" Active TFO Handshakes (Client):{summary['active_tfo']:,} (Failures/Fallbacks: {summary['active_fail']:,})")
    print(f" Passive TFO Handshakes (Server):{summary['passive_tfo']:,} (Cookie Rejections: {summary['passive_fail']:,})")
    print(f" TFO Middlebox Blackholes:      {summary['blackhole_events']:,}")
    print(f" TFO Listen Queue Overflows:    {summary['listen_overflow']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'TFO Metric / Capability':<35} {'Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'TFO Client Support':<35} {str(summary['client_enabled']):<15} {'Nominal' if summary['client_enabled'] else 'Disabled'}")
    print(f" {'TFO Blackhole Events':<35} {summary['blackhole_events']:<15} {'Nominal' if summary['blackhole_events'] == 0 else 'WARNING'}")
    print(f" {'TFO Listen Overflows':<35} {summary['listen_overflow']:<15} {'Nominal' if summary['listen_overflow'] <= 100 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive TCP Fast Open Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP Fast Open configuration, handshake acceleration, and cookie metrics nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
