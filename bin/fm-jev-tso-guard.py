#!/usr/bin/env python3
"""
fm-jev-tso-guard.py - Jev Multi-Agent Host Network TCP Segmentation Offload Guard (Pattern 122)

Audits Linux network interface TCP segmentation offload (TSO), generic segmentation offload (GSO),
generic receive offload (GRO), and NIC hardware ring buffer miss counters from ethtool,
/proc/sys/net/ipv4/tcp_limit_output_bytes, and /proc/sys/net/core/default_qdisc.

Detects disabled hardware offloads causing excessive CPU segmentation overhead, undersized TSO output limits,
and hardware DMA ring overruns (rx_missed/rx_no_buffer_count) across high-throughput multi-agent transfers.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when ethtool is unavailable or interfaces are virtual.
  - Fast bounded execution (< 0.04s).
"""

import argparse
import json
import os
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

SYSCTL_LIMIT_OUTPUT = "/proc/sys/net/ipv4/tcp_limit_output_bytes"
SYSCTL_DEFAULT_QDISC = "/proc/sys/net/core/default_qdisc"
SYSFS_NET = "/sys/class/net"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def read_str_file(path: Path) -> Optional[str]:
    """Reads a string from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return path.read_text().strip()
    except Exception:
        return None


def get_active_interfaces(net_dir: Path) -> List[str]:
    """Finds active non-loopback network interfaces."""
    if not net_dir.is_dir():
        return ["lo"]
    ifaces: List[str] = []
    for p in sorted(net_dir.iterdir()):
        if p.name == "lo":
            continue
        operstate = read_str_file(p / "operstate")
        if operstate in ("up", "unknown"):
            ifaces.append(p.name)
    return ifaces or ["lo"]


def get_interface_offloads(iface: str) -> Dict[str, bool]:
    """Queries offload features using ethtool."""
    offloads: Dict[str, bool] = {
        "tso": True,
        "gso": True,
        "gro": True,
    }
    if not shutil.which("ethtool"):
        return offloads

    try:
        cmd = ["ethtool", "-k", iface]
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=1).decode("utf-8")
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("tcp-segmentation-offload:"):
                offloads["tso"] = "on" in line.split(":", 1)[1]
            elif line.startswith("generic-segmentation-offload:"):
                offloads["gso"] = "on" in line.split(":", 1)[1]
            elif line.startswith("generic-receive-offload:"):
                offloads["gro"] = "on" in line.split(":", 1)[1]
    except Exception:
        pass
    return offloads


def get_interface_nic_stats(iface: str) -> Dict[str, int]:
    """Queries NIC hardware drop counters via ethtool -S."""
    stats: Dict[str, int] = {
        "rx_missed": 0,
        "rx_errors": 0,
        "tx_underrun": 0,
        "tx_aborted": 0,
    }
    if not shutil.which("ethtool"):
        return stats

    try:
        cmd = ["ethtool", "-S", iface]
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=1).decode("utf-8")
        for line in out.splitlines():
            parts = line.strip().split(":")
            if len(parts) == 2:
                k = parts[0].strip().lower()
                try:
                    v = int(parts[1].strip())
                    if "rx_missed" in k or "rx_no_buffer_count" in k:
                        stats["rx_missed"] += v
                    elif "rx_errors" in k:
                        stats["rx_errors"] += v
                    elif "tx_underrun" in k:
                        stats["tx_underrun"] += v
                    elif "tx_aborted" in k:
                        stats["tx_aborted"] += v
                except ValueError:
                    continue
    except Exception:
        pass
    return stats


def audit_tso(
    limit_file: Optional[str] = None,
    qdisc_file: Optional[str] = None,
    net_dir: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host TCP Segmentation Offload, qdisc, and NIC ring stalls."""
    limit_p = Path(limit_file or SYSCTL_LIMIT_OUTPUT)
    qdisc_p = Path(qdisc_file or SYSCTL_DEFAULT_QDISC)
    net_p = Path(net_dir or SYSFS_NET)

    tcp_limit_output_bytes = read_int_file(limit_p)
    if tcp_limit_output_bytes is None:
        tcp_limit_output_bytes = 4194304

    default_qdisc = read_str_file(qdisc_p) or "fq_codel"
    active_ifaces = get_active_interfaces(net_p)

    iface_reports: Dict[str, Any] = {}
    issues: List[str] = []
    healthy = True

    total_rx_missed = 0
    total_rx_errors = 0
    total_tx_underrun = 0

    for iface in active_ifaces:
        offloads = get_interface_offloads(iface)
        nic_stats = get_interface_nic_stats(iface)

        total_rx_missed += nic_stats["rx_missed"]
        total_rx_errors += nic_stats["rx_errors"]
        total_tx_underrun += nic_stats["tx_underrun"]

        iface_reports[iface] = {
            "offloads": offloads,
            "nic_stats": nic_stats,
        }

        if not offloads["tso"] or not offloads["gso"]:
            issues.append(f"TSO/GSO disabled on interface '{iface}'. Software segmentation will increase kernel CPU usage.")

    if tcp_limit_output_bytes < 131072:
        healthy = False
        issues.append(f"tcp_limit_output_bytes is low ({tcp_limit_output_bytes} < 128KB). Limits TSO burst throughput.")

    if total_rx_missed > 50000:
        healthy = False
        issues.append(f"Elevated NIC hardware DMA ring misses ({total_rx_missed:,} rx_missed). Host ring buffer starvation under load.")

    if total_tx_underrun > 0:
        healthy = False
        issues.append(f"NIC hardware transmit underruns detected ({total_tx_underrun:,} tx_underrun). PCIe bus latency issue.")

    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "tcp_limit_output_bytes": tcp_limit_output_bytes,
            "default_qdisc": default_qdisc,
            "active_interfaces": active_ifaces,
            "total_rx_missed": total_rx_missed,
            "total_rx_errors": total_rx_errors,
            "total_tx_underrun": total_tx_underrun,
            "issues": issues,
        },
        "interfaces": iface_reports,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Segmentation Offload Guard (Pattern 122)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--limit-file", type=str, default=None, help="Path to tcp_limit_output_bytes")
    parser.add_argument("--qdisc-file", type=str, default=None, help="Path to default_qdisc")
    parser.add_argument("--net-dir", type=str, default=None, help="Path to /sys/class/net")
    args = parser.parse_args()

    result = audit_tso(
        limit_file=args.limit_file,
        qdisc_file=args.qdisc_file,
        net_dir=args.net_dir,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP Segmentation Offload Guard (Pattern 122)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" TCP Limit Output Bytes:        {summary['tcp_limit_output_bytes']:,} B ({summary['tcp_limit_output_bytes'] // (1024*1024)} MB)")
    print(f" Default Queuing Discipline:    {summary['default_qdisc']}")
    print(f" Total RX Missed (DMA Overrun): {summary['total_rx_missed']:,}")
    print(f" Total RX Errors:               {summary['total_rx_errors']:,}")
    print(f" Total TX Underruns:            {summary['total_tx_underrun']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Interface':<15} {'TSO':<8} {'GSO':<8} {'GRO':<8} {'RX Missed':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    for iface, data in result["interfaces"].items():
        offs = data["offloads"]
        nstats = data["nic_stats"]
        tso_s = "ON" if offs["tso"] else "OFF"
        gso_s = "ON" if offs["gso"] else "OFF"
        gro_s = "ON" if offs["gro"] else "OFF"
        st = "Nominal" if offs["tso"] and offs["gso"] else "Warning"
        print(f" {iface:<15} {tso_s:<8} {gso_s:<8} {gro_s:<8} {nstats['rx_missed']:<15} {st}")

    if summary["issues"]:
        print("\nActive TCP Segmentation Offload Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP segmentation offloads and NIC hardware ring parameters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
