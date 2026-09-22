#!/usr/bin/env python3
"""
fm-jev-udp-guard.py - Jev Multi-Agent Host Network UDP Socket Buffer Overflow & Datagram Drop Guard (Pattern 98)

Audits Linux host UDP socket buffer parameters and datagram error counters from /proc/net/snmp and
/proc/sys/net/core/rmem_default, rmem_max, wmem_default, wmem_max, /proc/sys/net/ipv4/udp_mem.

Detects socket receive/send buffer drops, memory pressure, and checksum corruptions during intense multi-agent
telemetry, logging (e.g. statsd/syslog), and distributed RPC UDP traffic.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when /proc files are missing or restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

PROC_SNMP = "/proc/net/snmp"
SYSCTL_RMEM_DEFAULT = "/proc/sys/net/core/rmem_default"
SYSCTL_RMEM_MAX = "/proc/sys/net/core/rmem_max"
SYSCTL_WMEM_DEFAULT = "/proc/sys/net/core/wmem_default"
SYSCTL_WMEM_MAX = "/proc/sys/net/core/wmem_max"
SYSCTL_UDP_MEM = "/proc/sys/net/ipv4/udp_mem"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def read_udp_mem(path: Path) -> Tuple[Optional[int], Optional[int], Optional[int]]:
    """Reads 3 memory thresholds from udp_mem (min, pressure, max in pages)."""
    if not path.is_file():
        return None, None, None
    try:
        parts = path.read_text().strip().split()
        if len(parts) >= 3:
            return int(parts[0]), int(parts[1]), int(parts[2])
    except Exception:
        pass
    return None, None, None


def parse_snmp_udp(snmp_path: Path) -> Dict[str, int]:
    """Parses Udp: line from /proc/net/snmp."""
    if not snmp_path.is_file():
        return {}

    metrics: Dict[str, int] = {}
    try:
        lines = snmp_path.read_text().splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("Udp:") and lines[i + 1].startswith("Udp:"):
                keys = lines[i].split()[1:]
                vals = lines[i + 1].split()[1:]
                for k, v in zip(keys, vals):
                    try:
                        metrics[k] = int(v)
                    except ValueError:
                        continue
                break
    except Exception:
        return {}

    return metrics


def audit_udp_buffers(
    snmp_file: Optional[str] = None,
    rmem_default_file: Optional[str] = None,
    rmem_max_file: Optional[str] = None,
    wmem_default_file: Optional[str] = None,
    wmem_max_file: Optional[str] = None,
    udp_mem_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits UDP buffer sizing, drop rates, and packet errors."""
    snmp_path = Path(snmp_file) if snmp_file else Path(PROC_SNMP)
    rmem_def_path = Path(rmem_default_file) if rmem_default_file else Path(SYSCTL_RMEM_DEFAULT)
    rmem_max_path = Path(rmem_max_file) if rmem_max_file else Path(SYSCTL_RMEM_MAX)
    wmem_def_path = Path(wmem_default_file) if wmem_default_file else Path(SYSCTL_WMEM_DEFAULT)
    wmem_max_path = Path(wmem_max_file) if wmem_max_file else Path(SYSCTL_WMEM_MAX)
    udp_mem_path = Path(udp_mem_file) if udp_mem_file else Path(SYSCTL_UDP_MEM)

    rmem_default = read_int_file(rmem_def_path)
    rmem_max = read_int_file(rmem_max_path)
    wmem_default = read_int_file(wmem_def_path)
    wmem_max = read_int_file(wmem_max_path)
    udp_min, udp_pressure, udp_max = read_udp_mem(udp_mem_path)

    udp_stats = parse_snmp_udp(snmp_path)

    in_datagrams = udp_stats.get("InDatagrams", 0)
    out_datagrams = udp_stats.get("OutDatagrams", 0)
    rcvbuf_errors = udp_stats.get("RcvbufErrors", 0)
    sndbuf_errors = udp_stats.get("SndbufErrors", 0)
    in_errors = udp_stats.get("InErrors", 0)
    no_ports = udp_stats.get("NoPorts", 0)
    in_csum_errors = udp_stats.get("InCsumErrors", 0)
    mem_errors = udp_stats.get("MemErrors", 0)

    rcv_drop_pct = (rcvbuf_errors / in_datagrams * 100.0) if in_datagrams > 0 else 0.0
    snd_drop_pct = (sndbuf_errors / out_datagrams * 100.0) if out_datagrams > 0 else 0.0

    issues: List[str] = []

    if rmem_default is not None and rmem_default < 65536:
        issues.append(f"Low core rmem_default ({rmem_default} < 65,536 bytes): risk of buffer starvation")

    if mem_errors > 0:
        issues.append(f"Kernel UDP memory errors detected ({mem_errors}): allocation failure under pressure")

    if rcv_drop_pct > 1.0:
        issues.append(f"Elevated UDP receive buffer drop rate ({rcv_drop_pct:.2f}% of {in_datagrams} datagrams): socket buffer overflow")

    if snd_drop_pct > 1.0:
        issues.append(f"Elevated UDP send buffer drop rate ({snd_drop_pct:.2f}% of {out_datagrams} datagrams): socket send buffer full")

    if in_csum_errors > 100:
        issues.append(f"High UDP checksum errors ({in_csum_errors}): datagram corruption in transit")

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "in_datagrams": in_datagrams,
            "out_datagrams": out_datagrams,
            "rcvbuf_errors": rcvbuf_errors,
            "rcv_drop_pct": round(rcv_drop_pct, 4),
            "sndbuf_errors": sndbuf_errors,
            "snd_drop_pct": round(snd_drop_pct, 4),
            "in_errors": in_errors,
            "mem_errors": mem_errors,
            "rmem_default": rmem_default,
            "rmem_max": rmem_max,
            "wmem_default": wmem_default,
            "wmem_max": wmem_max,
            "udp_mem_pages": {
                "min": udp_min,
                "pressure": udp_pressure,
                "max": udp_max,
            },
            "issues": issues,
        },
        "counters": {
            "in_datagrams": in_datagrams,
            "out_datagrams": out_datagrams,
            "rcvbuf_errors": rcvbuf_errors,
            "sndbuf_errors": sndbuf_errors,
            "in_errors": in_errors,
            "no_ports": no_ports,
            "in_csum_errors": in_csum_errors,
            "mem_errors": mem_errors,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network UDP Socket Buffer Overflow & Datagram Drop Guard (Pattern 98)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--snmp-file", type=str, default=None, help="Path to /proc/net/snmp")
    parser.add_argument("--rmem-def-file", type=str, default=None, help="Path to rmem_default")
    parser.add_argument("--rmem-max-file", type=str, default=None, help="Path to rmem_max")
    parser.add_argument("--wmem-def-file", type=str, default=None, help="Path to wmem_default")
    parser.add_argument("--wmem-max-file", type=str, default=None, help="Path to wmem_max")
    parser.add_argument("--udp-mem-file", type=str, default=None, help="Path to udp_mem")
    args = parser.parse_args()

    result = audit_udp_buffers(
        snmp_file=args.snmp_file,
        rmem_default_file=args.rmem_def_file,
        rmem_max_file=args.rmem_max_file,
        wmem_default_file=args.wmem_def_file,
        wmem_max_file=args.wmem_max_file,
        udp_mem_file=args.udp_mem_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network UDP Socket Buffer Overflow Guard (Pattern 98)")
    print("================================================================================")
    print(f" Timestamp:                 {result['timestamp']}")
    print(f" Status:                    {status_color}{summary['status']}{reset_color}")
    print(f" RMEM Default / Max:        {summary['rmem_default']} / {summary['rmem_max']} bytes")
    print(f" WMEM Default / Max:        {summary['wmem_default']} / {summary['wmem_max']} bytes")
    print(f" UDP Mem Thresholds:        min={summary['udp_mem_pages']['min']}, pressure={summary['udp_mem_pages']['pressure']}, max={summary['udp_mem_pages']['max']} pages")
    print("--------------------------------------------------------------------------------")
    print(f" {'Metric':<30} {'Count':<15} {'Drop % / Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'In Datagrams':<30} {counters['in_datagrams']:<15} Nominal")
    print(f" {'Out Datagrams':<30} {counters['out_datagrams']:<15} Nominal")
    print(f" {'Rcv Buffer Errors (Drops)':<30} {counters['rcvbuf_errors']:<15} {summary['rcv_drop_pct']}% {'(Nominal)' if summary['rcv_drop_pct'] <= 1.0 else '(WARNING)'}")
    print(f" {'Snd Buffer Errors (Drops)':<30} {counters['sndbuf_errors']:<15} {summary['snd_drop_pct']}% {'(Nominal)' if summary['snd_drop_pct'] <= 1.0 else '(WARNING)'}")
    print(f" {'General In Errors':<30} {counters['in_errors']:<15} Nominal")
    print(f" {'No Port Destination':<30} {counters['no_ports']:<15} Nominal")
    print(f" {'Checksum Errors':<30} {counters['in_csum_errors']:<15} {'Nominal' if counters['in_csum_errors'] <= 100 else 'WARNING'}")
    print(f" {'Memory Errors':<30} {counters['mem_errors']:<15} {'Nominal' if counters['mem_errors'] == 0 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive UDP Socket Buffer Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll UDP socket buffer sizes, drop ratios, and datagram error counters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
