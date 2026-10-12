#!/usr/bin/env python3
"""
bin/fm-jev-ipv4-martian-guard.py - Linux IPv4 Martian Logging, Source Valid Mark & IPsec Policy Guard (Pattern 292 / Pattern 430)

Audits Linux kernel IPv4 Martian logging, FIB source valid mark policy, and IPsec policy bypass settings across all interfaces:
  - /proc/sys/net/ipv4/conf/*/log_martians: Log packets with impossible addresses to dmesg (0=disabled, 1=enabled)
  - /proc/sys/net/ipv4/conf/*/src_valid_mark: Use skb mark in FIB lookup for reverse path validation (0=disabled, 1=enabled)
  - /proc/sys/net/ipv4/conf/*/disable_policy: Disable IPsec policy checks (0=enforced, 1=disabled; must be 0 on physical interfaces)
  - /proc/sys/net/ipv4/conf/*/disable_xfrm: Disable IPsec transformation (0=enforced, 1=disabled; must be 0 on physical interfaces)
  - /proc/net/snmp: InDiscards, InNoRoutes, InAddrErrors, InUnknownProtos
  - /proc/net/netstat: IPReversePathFilter

Invariants:
  - log_martians must be 0 or 1 across all interfaces (0 recommended to prevent dmesg log exhaustion).
  - src_valid_mark must be 0 or 1 across all interfaces.
  - disable_policy must be 0 on non-loopback interfaces (1 permitted on lo for local IPC performance).
  - disable_xfrm must be 0 on non-loopback interfaces (1 permitted on lo for local IPC performance).
  - Fail-open: graceful fallback when sysctl paths or /proc/net are restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

CONF_IPV4_BASE = "/proc/sys/net/ipv4/conf"
PROC_SNMP = "/proc/net/snmp"
PROC_NETSTAT = "/proc/net/netstat"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content and (content.split()[0].lstrip("-").isdigit()) else default
    except (ValueError, OSError, IndexError):
        return default


def parse_snmp_ip(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("Ip:") and lines[i + 1].startswith("Ip:"):
                keys = lines[i].split()[1:]
                vals = lines[i + 1].split()[1:]
                for k, v in zip(keys, vals):
                    try:
                        metrics[k] = int(v)
                    except ValueError:
                        pass
                break
    except Exception:
        pass
    return metrics


def parse_netstat_tcpext(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("TcpExt:") and lines[i + 1].startswith("TcpExt:"):
                keys = lines[i].split()[1:]
                vals = lines[i + 1].split()[1:]
                for k, v in zip(keys, vals):
                    try:
                        metrics[k] = int(v)
                    except ValueError:
                        pass
                break
    except Exception:
        pass
    return metrics


def evaluate_ipv4_martian_policy(
    conf_dir: str = CONF_IPV4_BASE,
    snmp_path: str = PROC_SNMP,
    netstat_path: str = PROC_NETSTAT,
) -> Dict[str, Any]:
    interfaces: Dict[str, Dict[str, int]] = {}
    issues: List[str] = []

    if os.path.isdir(conf_dir):
        try:
            for entry in sorted(os.listdir(conf_dir)):
                iface_dir = os.path.join(conf_dir, entry)
                if not os.path.isdir(iface_dir):
                    continue

                log_martians = read_sysctl_int(os.path.join(iface_dir, "log_martians"), default=-1)
                src_valid_mark = read_sysctl_int(os.path.join(iface_dir, "src_valid_mark"), default=-1)
                disable_policy = read_sysctl_int(os.path.join(iface_dir, "disable_policy"), default=-1)
                disable_xfrm = read_sysctl_int(os.path.join(iface_dir, "disable_xfrm"), default=-1)

                if log_martians != -1 or src_valid_mark != -1:
                    interfaces[entry] = {
                        "log_martians": log_martians,
                        "src_valid_mark": src_valid_mark,
                        "disable_policy": disable_policy,
                        "disable_xfrm": disable_xfrm,
                    }

                    if log_martians not in (-1, None) and log_martians not in (0, 1):
                        issues.append(
                            f"Interface {entry} log_martians={log_martians} invalid (must be 0 or 1)"
                        )
                    if src_valid_mark not in (-1, None) and src_valid_mark not in (0, 1):
                        issues.append(
                            f"Interface {entry} src_valid_mark={src_valid_mark} invalid (must be 0 or 1)"
                        )
                    if entry != "lo":
                        if disable_policy == 1:
                            issues.append(
                                f"Interface {entry} disable_policy=1 (IPsec policy verification bypassed on physical interface)"
                            )
                        if disable_xfrm == 1:
                            issues.append(
                                f"Interface {entry} disable_xfrm=1 (IPsec transformations bypassed on physical interface)"
                            )
        except OSError:
            pass

    snmp = parse_snmp_ip(snmp_path)
    netstat = parse_netstat_tcpext(netstat_path)

    in_discards = snmp.get("InDiscards", 0)
    in_no_routes = snmp.get("InNoRoutes", 0)
    in_addr_errors = snmp.get("InAddrErrors", 0)
    in_unknown_protos = snmp.get("InUnknownProtos", 0)
    rp_filter_drops = netstat.get("IPReversePathFilter", 0)

    all_log_martians = interfaces.get("all", {}).get("log_martians", 0)
    default_log_martians = interfaces.get("default", {}).get("log_martians", 0)
    all_src_valid_mark = interfaces.get("all", {}).get("src_valid_mark", 0)
    default_src_valid_mark = interfaces.get("default", {}).get("src_valid_mark", 0)

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "DEGRADED"

    return {
        "pattern": 292,
        "name": "ipv4_martian",
        "description": "Host Network IPv4 Martian Logging, Source Valid Mark & IPsec Policy Guard",
        "status": status,
        "healthy": healthy,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "interfaces_audited": len(interfaces),
        "all_log_martians": all_log_martians,
        "default_log_martians": default_log_martians,
        "all_src_valid_mark": all_src_valid_mark,
        "default_src_valid_mark": default_src_valid_mark,
        "in_discards": in_discards,
        "in_no_routes": in_no_routes,
        "in_addr_errors": in_addr_errors,
        "in_unknown_protos": in_unknown_protos,
        "rp_filter_drops": rp_filter_drops,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IPv4 Martian Logging, Source Valid Mark & IPsec Policy Guard"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--conf-dir", default=CONF_IPV4_BASE, help="Path to IPv4 conf sysctl directory")
    parser.add_argument("--snmp-path", default=PROC_SNMP, help="Path to snmp stats file")
    parser.add_argument("--netstat-path", default=PROC_NETSTAT, help="Path to netstat stats file")
    args = parser.parse_args()

    result = evaluate_ipv4_martian_policy(
        conf_dir=args.conf_dir,
        snmp_path=args.snmp_path,
        netstat_path=args.netstat_path,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] {result['description']}")
        print(f"  Interfaces Audited: {result['interfaces_audited']}")
        print(f"  Log Martians (all): {result['all_log_martians']}, Default: {result['default_log_martians']}")
        print(f"  Source Valid Mark (all): {result['all_src_valid_mark']}, Default: {result['default_src_valid_mark']}")
        print(f"  Inbound Discards: {result['in_discards']}, Inbound No Routes: {result['in_no_routes']}")
        print(f"  Inbound Address Errors: {result['in_addr_errors']}, RP Filter Drops: {result['rp_filter_drops']}")
        if result["issues"]:
            print("  Issues:")
            for issue in result["issues"]:
                print(f"    - {issue}")

    return 0 if result["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
