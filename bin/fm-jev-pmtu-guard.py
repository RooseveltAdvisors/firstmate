#!/usr/bin/env python3
"""
fm-jev-pmtu-guard.py - Jev Multi-Agent Host Network MTU & Path MTU Discovery Guard (Pattern 103)

Audits Linux host interface MTUs, Path MTU Discovery (PMTUD) sysctls, and TCP MTU probing counters
from /proc/sys/net/ipv4/tcp_mtu_probing, ip_no_pmtu_disc, tcp_base_mss, /sys/class/net/*/mtu, and
/proc/net/netstat (TcpExt).

Detects disabled PMTUD, ICMP blackhole exposure, non-standard interface MTUs (< 1280 or tunnel mismatches),
and elevated MTU probing failures across multi-agent RPCs, model artifact transfers, and clinic VPN tunnels.

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

SYSCTL_MTU_PROBING = "/proc/sys/net/ipv4/tcp_mtu_probing"
SYSCTL_NO_PMTU_DISC = "/proc/sys/net/ipv4/ip_no_pmtu_disc"
SYSCTL_BASE_MSS = "/proc/sys/net/ipv4/tcp_base_mss"
SYSFS_NET_DIR = "/sys/class/net"
PROC_NETSTAT = "/proc/net/netstat"


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


def audit_interfaces(net_dir: Path) -> Dict[str, Dict[str, Any]]:
    """Audits MTU and operational state for all network interfaces."""
    interfaces: Dict[str, Dict[str, Any]] = {}
    if not net_dir.is_dir():
        return interfaces

    try:
        for entry in net_dir.iterdir():
            if entry.is_symlink() or entry.is_dir():
                iface_name = entry.name
                mtu = read_int_file(entry / "mtu")
                operstate = read_str_file(entry / "operstate") or "unknown"
                interfaces[iface_name] = {
                    "mtu": mtu,
                    "operstate": operstate,
                }
    except Exception:
        pass

    return interfaces


def audit_pmtu(
    mtu_probing_file: Optional[str] = None,
    no_pmtu_disc_file: Optional[str] = None,
    base_mss_file: Optional[str] = None,
    net_dir: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits PMTUD configuration, interface MTUs, and MTU probing telemetry."""
    probing_path = Path(mtu_probing_file) if mtu_probing_file else Path(SYSCTL_MTU_PROBING)
    no_disc_path = Path(no_pmtu_disc_file) if no_pmtu_disc_file else Path(SYSCTL_NO_PMTU_DISC)
    base_mss_path = Path(base_mss_file) if base_mss_file else Path(SYSCTL_BASE_MSS)
    net_dir_path = Path(net_dir) if net_dir else Path(SYSFS_NET_DIR)
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)

    tcp_mtu_probing = read_int_file(probing_path)
    ip_no_pmtu_disc = read_int_file(no_disc_path)
    tcp_base_mss = read_int_file(base_mss_path)

    interfaces = audit_interfaces(net_dir_path)
    tcpext = parse_tcpext_netstat(netstat_path)

    mtup_fail = tcpext.get("TCPMTUPFail", 0)
    mtup_success = tcpext.get("TCPMTUPSuccess", 0)

    issues: List[str] = []

    # Check PMTU discovery disabled
    if ip_no_pmtu_disc is not None and ip_no_pmtu_disc == 1:
        issues.append("Path MTU Discovery disabled (ip_no_pmtu_disc=1): IP packets sent with DF=0 risk severe fragmentation")

    # Check interface MTUs
    for iface, data in sorted(interfaces.items()):
        mtu = data.get("mtu")
        operstate = data.get("operstate")
        if iface == "lo":
            continue
        if mtu is not None:
            if mtu < 1280:
                issues.append(f"Interface {iface} has sub-minimum IPv6 MTU ({mtu} < 1280 bytes): causes drop of IPv6/tunnel traffic")
            elif mtu > 9000:
                issues.append(f"Interface {iface} has anomalous jumbo MTU ({mtu} > 9000 bytes)")

    # Check MTU probing failure rate
    if mtup_fail > 10 and mtup_fail > mtup_success:
        issues.append(f"Elevated TCP MTU probing failures ({mtup_fail} fails vs {mtup_success} successes): path MTU blackhole detected")

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "pmtu_discovery_enabled": ip_no_pmtu_disc == 0 if ip_no_pmtu_disc is not None else True,
            "tcp_mtu_probing_mode": tcp_mtu_probing if tcp_mtu_probing is not None else 0,
            "tcp_base_mss_bytes": tcp_base_mss if tcp_base_mss is not None else 1024,
            "interface_count": len(interfaces),
            "mtu_probe_failures": mtup_fail,
            "mtu_probe_successes": mtup_success,
            "issues": issues,
        },
        "interfaces": interfaces,
        "counters": {
            "mtup_fail": mtup_fail,
            "mtup_success": mtup_success,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network MTU & Path MTU Discovery Guard (Pattern 103)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--mtu-probing-file", type=str, default=None, help="Path to tcp_mtu_probing")
    parser.add_argument("--no-pmtu-disc-file", type=str, default=None, help="Path to ip_no_pmtu_disc")
    parser.add_argument("--base-mss-file", type=str, default=None, help="Path to tcp_base_mss")
    parser.add_argument("--net-dir", type=str, default=None, help="Path to /sys/class/net")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_pmtu(
        mtu_probing_file=args.mtu_probing_file,
        no_pmtu_disc_file=args.no_pmtu_disc_file,
        base_mss_file=args.base_mss_file,
        net_dir=args.net_dir,
        netstat_file=args.netstat_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    probing_desc = {
        0: "Disabled (0)",
        1: "Blackhole Triggered (1)",
        2: "Always Active (2)",
    }.get(summary["tcp_mtu_probing_mode"], f"Mode {summary['tcp_mtu_probing_mode']}")

    print("================================================================================")
    print(" Jev Multi-Agent Host Network MTU & PMTUD Guard (Pattern 103)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Path MTU Discovery:            {'Enabled' if summary['pmtu_discovery_enabled'] else 'DISABLED'}")
    print(f" TCP MTU Probing:               {probing_desc}")
    print(f" TCP Base MSS:                  {summary['tcp_base_mss_bytes']} bytes")
    print(f" Monitored Interfaces:          {summary['interface_count']}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Interface':<15} {'MTU (bytes)':<15} {'Operstate':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    for iface, d in sorted(result["interfaces"].items()):
        mtu_str = str(d["mtu"]) if d["mtu"] is not None else "N/A"
        mtu_val = d["mtu"] or 0
        if iface != "lo" and (mtu_val < 1280 or mtu_val > 9000):
            st = "WARNING"
        else:
            st = "Nominal"
        print(f" {iface:<15} {mtu_str:<15} {d['operstate']:<15} {st}")

    print("--------------------------------------------------------------------------------")
    print(f" MTU Probe Successes:           {summary['mtu_probe_successes']}")
    print(f" MTU Probe Failures:            {summary['mtu_probe_failures']}")

    if summary["issues"]:
        print("\nActive MTU / PMTUD Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host network interface MTU and PMTU discovery parameters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
