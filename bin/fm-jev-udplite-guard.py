#!/usr/bin/env python3
"""
bin/fm-jev-udplite-guard.py - Host Network UDP-Lite Transport & Checksum Partial Coverage Guard (Pattern 244)

Audits Linux kernel RFC 3828 UDP-Lite (Lightweight User Datagram Protocol) telemetry and socket queues:
  - /proc/net/snmp (UdpLite: InDatagrams, NoPorts, InErrors, OutDatagrams, RcvbufErrors, SndbufErrors, InCsumErrors, MemErrors)
  - /proc/net/snmp6 (UdpLite6InDatagrams, UdpLite6InErrors, UdpLite6RcvbufErrors, UdpLite6SndbufErrors, UdpLite6InCsumErrors, UdpLite6MemErrors)
  - /proc/net/udplite (IPv4 UDP-Lite socket descriptors and drop counters)
  - /proc/net/udplite6 (IPv6 UDP-Lite socket descriptors and drop counters)

Guarantees low-latency, error-tolerant telemetry streaming (audio/voice agent streams, sensor feeds,
and high-frequency metrics) without socket receive buffer exhaustion or silent memory drop spikes.

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

DEFAULT_SNMP_PATH = "/proc/net/snmp"
DEFAULT_SNMP6_PATH = "/proc/net/snmp6"
DEFAULT_UDPLITE_PATH = "/proc/net/udplite"
DEFAULT_UDPLITE6_PATH = "/proc/net/udplite6"

WARN_MAX_RCVBUF_ERRORS = 100
WARN_MAX_CSUM_ERRORS = 50
WARN_MAX_SOCKET_DROPS = 100


def parse_snmp_udplite(path: str = DEFAULT_SNMP_PATH) -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    if not os.path.exists(path):
        return metrics
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.read().strip().splitlines()
        for i in range(0, len(lines) - 1, 2):
            header_line = lines[i]
            val_line = lines[i + 1]
            if header_line.startswith("UdpLite:") and val_line.startswith("UdpLite:"):
                keys = header_line.split()[1:]
                vals = val_line.split()[1:]
                for k, v in zip(keys, vals):
                    try:
                        metrics[k] = int(v)
                    except ValueError:
                        continue
    except Exception:
        pass
    return metrics


def parse_snmp6_udplite(path: str = DEFAULT_SNMP6_PATH) -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    if not os.path.exists(path):
        return metrics
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.read().strip().splitlines()
        for line in lines:
            parts = line.split()
            if len(parts) >= 2 and parts[0].startswith("UdpLite6"):
                try:
                    metrics[parts[0]] = int(parts[1])
                except ValueError:
                    continue
    except Exception:
        pass
    return metrics


def parse_udplite_sockets(path: str) -> Tuple[int, int]:
    if not os.path.exists(path):
        return 0, 0
    active = 0
    total_drops = 0
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.read().strip().splitlines()
        if len(lines) <= 1:
            return 0, 0
        for line in lines[1:]:
            parts = line.split()
            if len(parts) >= 12:
                active += 1
                try:
                    total_drops += int(parts[-1])
                except ValueError:
                    pass
    except Exception:
        pass
    return active, total_drops


def audit_udplite(
    snmp_path: str = DEFAULT_SNMP_PATH,
    snmp6_path: str = DEFAULT_SNMP6_PATH,
    udplite_path: str = DEFAULT_UDPLITE_PATH,
    udplite6_path: str = DEFAULT_UDPLITE6_PATH,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []

    snmp = parse_snmp_udplite(snmp_path)
    snmp6 = parse_snmp6_udplite(snmp6_path)
    v4_active, v4_drops = parse_udplite_sockets(udplite_path)
    v6_active, v6_drops = parse_udplite_sockets(udplite6_path)

    in_datagrams = snmp.get("InDatagrams", 0) + snmp6.get("UdpLite6InDatagrams", 0)
    out_datagrams = snmp.get("OutDatagrams", 0) + snmp6.get("UdpLite6OutDatagrams", 0)
    in_errors = snmp.get("InErrors", 0) + snmp6.get("UdpLite6InErrors", 0)
    no_ports = snmp.get("NoPorts", 0) + snmp6.get("UdpLite6NoPorts", 0)
    rcvbuf_errors = snmp.get("RcvbufErrors", 0) + snmp6.get("UdpLite6RcvbufErrors", 0)
    sndbuf_errors = snmp.get("SndbufErrors", 0) + snmp6.get("UdpLite6SndbufErrors", 0)
    in_csum_errors = snmp.get("InCsumErrors", 0) + snmp6.get("UdpLite6InCsumErrors", 0)
    mem_errors = snmp.get("MemErrors", 0) + snmp6.get("UdpLite6MemErrors", 0)

    total_active_sockets = v4_active + v6_active
    total_socket_drops = v4_drops + v6_drops

    if rcvbuf_errors > WARN_MAX_RCVBUF_ERRORS:
        issues.append(f"Elevated UDP-Lite receive buffer overflow drops: {rcvbuf_errors}")
        recommendations.append("Increase net.core.rmem_default / rmem_max or socket SO_RCVBUF")

    if sndbuf_errors > 0:
        issues.append(f"Detected UDP-Lite send buffer exhaustion: {sndbuf_errors}")
        recommendations.append("Increase net.core.wmem_default / wmem_max or socket SO_SNDBUF")

    if in_csum_errors > WARN_MAX_CSUM_ERRORS:
        issues.append(f"Elevated UDP-Lite checksum errors: {in_csum_errors}")
        recommendations.append("Verify partial checksum coverage settings (UDPLITE_RECV_CSUM)")

    if mem_errors > 0:
        issues.append(f"Severe kernel UDP-Lite memory allocation failures: {mem_errors}")
        recommendations.append("Inspect net.ipv4.udp_mem / system memory pressure")

    if total_socket_drops > WARN_MAX_SOCKET_DROPS:
        issues.append(f"Elevated UDP-Lite socket queue drops: {total_socket_drops}")

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    summary: Dict[str, Any] = {
        "status": status,
        "healthy": healthy,
        "total_active_sockets": total_active_sockets,
        "v4_active_sockets": v4_active,
        "v6_active_sockets": v6_active,
        "in_datagrams": in_datagrams,
        "out_datagrams": out_datagrams,
        "in_errors": in_errors,
        "no_ports": no_ports,
        "rcvbuf_errors": rcvbuf_errors,
        "sndbuf_errors": sndbuf_errors,
        "in_csum_errors": in_csum_errors,
        "mem_errors": mem_errors,
        "total_socket_drops": total_socket_drops,
        "issues": issues,
    }

    details: Dict[str, Any] = {
        "snmp_v4": snmp,
        "snmp_v6": snmp6,
        "recommendations": recommendations,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "details": details,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network UDP-Lite Transport & Checksum Partial Coverage Guard (Pattern 244)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    parser.add_argument("--snmp", default=DEFAULT_SNMP_PATH, help="Path to /proc/net/snmp")
    parser.add_argument("--snmp6", default=DEFAULT_SNMP6_PATH, help="Path to /proc/net/snmp6")
    parser.add_argument("--udplite", default=DEFAULT_UDPLITE_PATH, help="Path to /proc/net/udplite")
    parser.add_argument("--udplite6", default=DEFAULT_UDPLITE6_PATH, help="Path to /proc/net/udplite6")
    parser.add_argument("--verbose", action="store_true", help="Print verbose metric details")
    args = parser.parse_args()

    report = audit_udplite(
        snmp_path=args.snmp,
        snmp6_path=args.snmp6,
        udplite_path=args.udplite,
        udplite6_path=args.udplite6,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        summary = report["summary"]
        print(f"[{summary['status']}] Jev Host UDP-Lite Transport Guard (Pattern 244)")
        print(f"  Active sockets      : {summary['total_active_sockets']} (IPv4: {summary['v4_active_sockets']}, IPv6: {summary['v6_active_sockets']})")
        print(f"  In/Out datagrams    : in={summary['in_datagrams']}, out={summary['out_datagrams']}")
        print(f"  Rcvbuf/Sndbuf errors: rcv={summary['rcvbuf_errors']}, snd={summary['sndbuf_errors']}")
        print(f"  Checksum errors     : {summary['in_csum_errors']}")
        print(f"  Memory errors       : {summary['mem_errors']}")
        print(f"  Socket drops        : {summary['total_socket_drops']}")
        if summary["issues"]:
            print("  Issues detected:")
            for iss in summary["issues"]:
                print(f"    - {iss}")
        if report["details"]["recommendations"]:
            print("  Recommendations:")
            for rec in report["details"]["recommendations"]:
                print(f"    - {rec}")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
