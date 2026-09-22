#!/usr/bin/env python3
"""
bin/fm-jev-udp-guard.py - Host Network UDP Datagram Buffer & Raw Socket Snooping Guard (Pattern 203)

Audits Linux kernel UDP protocol metrics, socket buffer memory allocations, and raw socket listeners from:
  - /proc/net/snmp (IPv4 UDP: InDatagrams, OutDatagrams, RcvbufErrors, SndbufErrors, InCsumErrors, MemErrors, NoPorts)
  - /proc/net/snmp6 (IPv6 UDP: Udp6InDatagrams, Udp6OutDatagrams, Udp6RcvbufErrors, Udp6SndbufErrors, Udp6InCsumErrors, Udp6MemErrors)
  - /proc/sys/net/ipv4/udp_mem, udp_rmem_min, udp_wmem_min
  - /proc/net/raw, /proc/net/raw6 (active raw socket bindings / packet snooping)
  - /proc/net/udp, /proc/net/udp6 (active UDP socket counts)

Detects UDP socket receive buffer drop surges, kernel UDP memory exhaustion, checksum corruption,
and rogue raw packet socket snooping across multi-agent cluster environments.

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


def read_sysctl_triplet(path: str, default: Tuple[int, int, int] = (-1, -1, -1)) -> Tuple[int, int, int]:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            parts = [int(p) for p in f.read().split()]
            if len(parts) >= 3:
                return (parts[0], parts[1], parts[2])
    except Exception:
        pass
    return default


def parse_snmp_udp(path: str = "/proc/net/snmp") -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    if not os.path.exists(path):
        return metrics
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = [line.strip() for line in f if line.strip().startswith("Udp:")]
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


def parse_snmp6_udp(path: str = "/proc/net/snmp6") -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    if not os.path.exists(path):
        return metrics
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) == 2 and parts[0].startswith("Udp6"):
                    try:
                        metrics[parts[0]] = int(parts[1])
                    except ValueError:
                        metrics[parts[0]] = 0
    except Exception:
        pass
    return metrics


def count_socket_lines(path: str) -> int:
    if not os.path.exists(path):
        return 0
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = [line for line in f if line.strip()]
        return max(0, len(lines) - 1)
    except Exception:
        return 0


def audit_udp(
    proc_snmp: str = "/proc/net/snmp",
    proc_snmp6: str = "/proc/net/snmp6",
    proc_sys_ipv4: str = "/proc/sys/net/ipv4",
    proc_raw: str = "/proc/net/raw",
    proc_raw6: str = "/proc/net/raw6",
    proc_udp: str = "/proc/net/udp",
    proc_udp6: str = "/proc/net/udp6",
) -> Dict[str, Any]:
    udp4 = parse_snmp_udp(proc_snmp)
    udp6 = parse_snmp6_udp(proc_snmp6)

    mem_path = os.path.join(proc_sys_ipv4, "udp_mem")
    rmem_min_path = os.path.join(proc_sys_ipv4, "udp_rmem_min")
    wmem_min_path = os.path.join(proc_sys_ipv4, "udp_wmem_min")

    udp_mem = read_sysctl_triplet(mem_path, (1525479, 2033974, 3050958))
    udp_rmem_min = read_sysctl_int(rmem_min_path, 4096)
    udp_wmem_min = read_sysctl_int(wmem_min_path, 4096)

    raw4_count = count_socket_lines(proc_raw)
    raw6_count = count_socket_lines(proc_raw6)
    raw_total = raw4_count + raw6_count

    udp4_active = count_socket_lines(proc_udp)
    udp6_active = count_socket_lines(proc_udp6)
    udp_active_total = udp4_active + udp6_active

    in_datagrams = udp4.get("InDatagrams", 0) + udp6.get("Udp6InDatagrams", 0)
    out_datagrams = udp4.get("OutDatagrams", 0) + udp6.get("Udp6OutDatagrams", 0)
    rcvbuf_errors = udp4.get("RcvbufErrors", 0) + udp6.get("Udp6RcvbufErrors", 0)
    sndbuf_errors = udp4.get("SndbufErrors", 0) + udp6.get("Udp6SndbufErrors", 0)
    in_csum_errors = udp4.get("InCsumErrors", 0) + udp6.get("Udp6InCsumErrors", 0)
    mem_errors = udp4.get("MemErrors", 0) + udp6.get("Udp6MemErrors", 0)
    no_ports = udp4.get("NoPorts", 0) + udp6.get("Udp6NoPorts", 0)
    ignored_multi = udp4.get("IgnoredMulti", 0) + udp6.get("Udp6IgnoredMulti", 0)

    rcvbuf_error_ratio = float(rcvbuf_errors) / max(1, in_datagrams)
    sndbuf_error_ratio = float(sndbuf_errors) / max(1, out_datagrams)
    csum_error_ratio = float(in_csum_errors) / max(1, in_datagrams)

    issues: List[str] = []
    status = "HEALTHY"

    if mem_errors > 0:
        issues.append(f"CRITICAL: Kernel UDP memory exhaustion detected ({mem_errors} MemErrors)")
        status = "CRITICAL"

    if rcvbuf_error_ratio > 0.05:
        issues.append(f"CRITICAL: Excessive UDP receive buffer drop ratio ({rcvbuf_error_ratio:.4%}, {rcvbuf_errors} drops)")
        status = "CRITICAL"
    elif rcvbuf_error_ratio > 0.01:
        issues.append(f"WARNING: Elevated UDP receive buffer drop ratio ({rcvbuf_error_ratio:.4%}, {rcvbuf_errors} drops)")
        if status != "CRITICAL":
            status = "WARNING"

    if raw_total > 5:
        issues.append(f"CRITICAL: Unusually high number of active raw packet sockets ({raw_total} raw sockets)")
        status = "CRITICAL"
    elif raw_total > 0:
        issues.append(f"NOTE: {raw_total} active raw socket(s) open (monitoring/ping/dhcp)")

    if csum_error_ratio > 0.01:
        issues.append(f"WARNING: High UDP checksum error ratio ({csum_error_ratio:.4%}, {in_csum_errors} corrupt packets)")
        if status != "CRITICAL":
            status = "WARNING"

    healthy = status == "HEALTHY"
    recommendation = (
        "UDP datagram buffers, memory limits, and socket states are nominal."
        if healthy
        else "; ".join(issues)
    )

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "in_datagrams": in_datagrams,
            "out_datagrams": out_datagrams,
            "rcvbuf_errors": rcvbuf_errors,
            "rcvbuf_error_ratio": round(rcvbuf_error_ratio, 6),
            "sndbuf_errors": sndbuf_errors,
            "sndbuf_error_ratio": round(sndbuf_error_ratio, 6),
            "in_csum_errors": in_csum_errors,
            "csum_error_ratio": round(csum_error_ratio, 6),
            "mem_errors": mem_errors,
            "no_ports": no_ports,
            "ignored_multi": ignored_multi,
            "raw_sockets_total": raw_total,
            "udp_sockets_active": udp_active_total,
            "udp_mem_pages": {
                "min": udp_mem[0],
                "pressure": udp_mem[1],
                "max": udp_mem[2],
            },
            "udp_rmem_min_bytes": udp_rmem_min,
            "udp_wmem_min_bytes": udp_wmem_min,
            "issues": issues,
            "recommendation": recommendation,
        },
        "raw_stats": {
            "udp4": udp4,
            "udp6": udp6,
            "raw4_count": raw4_count,
            "raw6_count": raw6_count,
            "udp4_active": udp4_active,
            "udp6_active": udp6_active,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network UDP Datagram Buffer & Raw Socket Snooping Guard (Pattern 203)"
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON telemetry")
    args = parser.parse_args()

    report = audit_udp()

    s = report["summary"]
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"[{s['status']}] Pattern 203: Host Network UDP Datagram Buffer Guard")
        print(f"  InDatagrams: {s['in_datagrams']:,} | OutDatagrams: {s['out_datagrams']:,}")
        print(f"  RcvbufErrors: {s['rcvbuf_errors']:,} ({s['rcvbuf_error_ratio']:.4%}) | SndbufErrors: {s['sndbuf_errors']:,}")
        print(f"  InCsumErrors: {s['in_csum_errors']:,} | MemErrors: {s['mem_errors']} | NoPorts: {s['no_ports']:,}")
        print(f"  Active UDP Sockets: {s['udp_sockets_active']:,} | Raw Sockets: {s['raw_sockets_total']:,}")
        print(f"  UDP Mem Limits (Pages): min={s['udp_mem_pages']['min']:,}, pressure={s['udp_mem_pages']['pressure']:,}, max={s['udp_mem_pages']['max']:,}")
        print(f"  Recommendation: {s['recommendation']}")

    return 0 if s["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
