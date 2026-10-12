#!/usr/bin/env python3
"""
fm-jev-rpfilter-guard.py - Jev Multi-Agent Host Network IP Reverse Path Filtering Guard (Pattern 121)

Audits Linux IPv4 reverse path filtering (rp_filter) settings across all network interfaces from
/proc/sys/net/ipv4/conf/*/rp_filter and correlates against reverse path drop counters from
/proc/net/netstat (TcpExt: IPReversePathFilter).

Detects asymmetric routing packet drops caused by RFC 3704 strict filtering (mode 1) in multi-homed workstations,
unprotected spoofing exposure (mode 0), and active reverse path drop events across container bridges and agent interfaces.

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

CONF_DIR = "/proc/sys/net/ipv4/conf"
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
                vals_raw = lines[i + 1].split()[1:]
                for k, v in zip(keys, vals_raw):
                    try:
                        metrics[k] = int(v)
                    except ValueError:
                        continue
                break
    except Exception:
        return {}

    return metrics


def audit_rpfilter(
    conf_dir: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host IPv4 reverse path filter configuration and drop counters."""
    conf_p = Path(conf_dir or CONF_DIR)
    netstat_p = Path(netstat_file or PROC_NETSTAT)

    interfaces: Dict[str, int] = {}
    if conf_p.is_dir():
        for p in sorted(conf_p.glob("*/rp_filter")):
            val = read_int_file(p)
            if val is not None:
                interfaces[p.parent.name] = val

    rp_all = interfaces.get("all", 2)
    rp_default = interfaces.get("default", 2)

    tcpext = parse_tcpext_netstat(netstat_p)
    rp_drops = tcpext.get("IPReversePathFilter", 0)

    issues: List[str] = []
    healthy = True

    if rp_all == 0:
        healthy = False
        issues.append("rp_filter is disabled globally (conf/all/rp_filter = 0). Vulnerable to source address spoofing.")
    elif rp_all == 1:
        healthy = False
        issues.append("rp_filter is set to strict mode (1) on all interfaces. In multi-homed or container environments, return traffic may be dropped.")

    if rp_drops > 0:
        healthy = False
        issues.append(f"Reverse path filtering drops detected ({rp_drops:,} packets dropped). Packets discarded due to route asymmetry.")

    # Check for strict mode on individual active interfaces (excluding lo)
    strict_ifaces = [iface for iface, val in interfaces.items() if val == 1 and iface not in ("all", "default", "lo")]
    if strict_ifaces:
        issues.append(f"Strict rp_filter (1) enabled on interfaces: {', '.join(strict_ifaces)}. Risk of silent drops during multi-interface routing.")

    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "rp_filter_all": rp_all,
            "rp_filter_default": rp_default,
            "interfaces_audited": len(interfaces),
            "rp_drops": rp_drops,
            "strict_interfaces": strict_ifaces,
            "issues": issues,
        },
        "interfaces": interfaces,
        "counters": {
            "rp_drops": rp_drops,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network IP Reverse Path Filtering Guard (Pattern 121)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--conf-dir", type=str, default=None, help="Path to /proc/sys/net/ipv4/conf")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_rpfilter(
        conf_dir=args.conf_dir,
        netstat_file=args.netstat_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    mode_map = {0: "Disabled (0)", 1: "Strict RFC3704 (1)", 2: "Loose RFC3704 (2)"}

    print("================================================================================")
    print(" Jev Multi-Agent Host Network IP Reverse Path Filtering Guard (Pattern 121)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Global rp_filter (all):        {mode_map.get(summary['rp_filter_all'], str(summary['rp_filter_all']))}")
    print(f" Default rp_filter:             {mode_map.get(summary['rp_filter_default'], str(summary['rp_filter_default']))}")
    print(f" Total Reverse Path Drops:      {summary['rp_drops']:,}")
    print(f" Interfaces Audited:            {summary['interfaces_audited']}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Interface':<25} {'rp_filter Mode':<25} {'Status'}")
    print("--------------------------------------------------------------------------------")
    for iface, val in result["interfaces"].items():
        mode_str = mode_map.get(val, f"Mode {val}")
        st = "Nominal" if val in (0, 2) or iface in ("all", "default") else "Strict"
        print(f" {iface:<25} {mode_str:<25} {st}")

    if summary["issues"]:
        print("\nActive IP Reverse Path Filter Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host IPv4 reverse path filter parameters and drop counters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
