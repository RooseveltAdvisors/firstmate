#!/usr/bin/env python3
"""
bin/fm-jev-ipv4-l2-policy-guard.py - Linux IPv4 L2 Multicast Unicast Drop, Secondary Promotion & Carrier Eviction Guard (Pattern 293 / Pattern 431)

Audits Linux kernel IPv4 L2 frame filtering, secondary address promotion, and neighbor eviction settings across all interfaces:
  - /proc/sys/net/ipv4/conf/*/drop_unicast_in_l2_multicast: Drop packets addressed to unicast IP in L2 broadcast/multicast frames (0=pass, 1=drop)
  - /proc/sys/net/ipv4/conf/*/promote_secondaries: Promote secondary IP addresses when primary address is deleted (0=purge, 1=promote)
  - /proc/sys/net/ipv4/conf/*/arp_evict_nocarrier: Evict neighbor table entries when interface loses carrier (0=keep, 1=evict)
  - /proc/sys/net/ipv4/conf/*/drop_gratuitous_arp: Drop gratuitous ARP requests/replies (0=accept, 1=drop)
  - /proc/net/snmp: InDiscards, InAddrErrors, InUnknownProtos
  - /proc/net/stat/arp_cache: lookups, hits, res_failed, forced_gc_runs, unresolved_discards, table_fulls

Invariants:
  - drop_unicast_in_l2_multicast must be 0 or 1 across all interfaces.
  - promote_secondaries must be 0 or 1 across all interfaces.
  - arp_evict_nocarrier must be 0 or 1 across all interfaces (1 recommended for carrier transitions).
  - drop_gratuitous_arp must be 0 or 1 across all interfaces.
  - ARP cache table_fulls must be 0 (no cache overflow drops).
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
PROC_ARP_CACHE = "/proc/net/stat/arp_cache"


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


def parse_arp_cache_stats(path: str) -> Dict[str, int]:
    totals: Dict[str, int] = {
        "entries": 0,
        "allocs": 0,
        "destroys": 0,
        "hash_grows": 0,
        "lookups": 0,
        "hits": 0,
        "res_failed": 0,
        "rcv_probes_mcast": 0,
        "rcv_probes_ucast": 0,
        "periodic_gc_runs": 0,
        "forced_gc_runs": 0,
        "unresolved_discards": 0,
        "table_fulls": 0,
    }
    if not os.path.isfile(path):
        return totals

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        if not lines:
            return totals
        header = lines[0].split()
        for line in lines[1:]:
            parts = line.split()
            if len(parts) != len(header):
                continue
            for idx, col_name in enumerate(header):
                if col_name in totals:
                    try:
                        totals[col_name] += int(parts[idx], 16)
                    except ValueError:
                        pass
    except Exception:
        pass
    return totals


def evaluate_ipv4_l2_policy(
    conf_dir: str = CONF_IPV4_BASE,
    snmp_path: str = PROC_SNMP,
    arp_cache_path: str = PROC_ARP_CACHE,
) -> Dict[str, Any]:
    interfaces: Dict[str, Dict[str, int]] = {}
    issues: List[str] = []
    recommendations: List[str] = []

    if os.path.isdir(conf_dir):
        try:
            for entry in sorted(os.listdir(conf_dir)):
                iface_dir = os.path.join(conf_dir, entry)
                if not os.path.isdir(iface_dir):
                    continue

                drop_unicast = read_sysctl_int(os.path.join(iface_dir, "drop_unicast_in_l2_multicast"), default=-1)
                promote_sec = read_sysctl_int(os.path.join(iface_dir, "promote_secondaries"), default=-1)
                arp_evict = read_sysctl_int(os.path.join(iface_dir, "arp_evict_nocarrier"), default=-1)
                drop_garp = read_sysctl_int(os.path.join(iface_dir, "drop_gratuitous_arp"), default=-1)

                if drop_unicast != -1 or promote_sec != -1:
                    interfaces[entry] = {
                        "drop_unicast_in_l2_multicast": drop_unicast,
                        "promote_secondaries": promote_sec,
                        "arp_evict_nocarrier": arp_evict,
                        "drop_gratuitous_arp": drop_garp,
                    }

                    if drop_unicast not in (-1, None) and drop_unicast not in (0, 1):
                        issues.append(
                            f"Interface {entry} drop_unicast_in_l2_multicast={drop_unicast} invalid (must be 0 or 1)"
                        )
                    if promote_sec not in (-1, None) and promote_sec not in (0, 1):
                        issues.append(
                            f"Interface {entry} promote_secondaries={promote_sec} invalid (must be 0 or 1)"
                        )
                    if arp_evict not in (-1, None) and arp_evict not in (0, 1):
                        issues.append(
                            f"Interface {entry} arp_evict_nocarrier={arp_evict} invalid (must be 0 or 1)"
                        )
                    if drop_garp not in (-1, None) and drop_garp not in (0, 1):
                        issues.append(
                            f"Interface {entry} drop_gratuitous_arp={drop_garp} invalid (must be 0 or 1)"
                        )
        except OSError:
            pass

    snmp = parse_snmp_ip(snmp_path)
    arp_cache = parse_arp_cache_stats(arp_cache_path)

    in_discards = snmp.get("InDiscards", 0)
    in_addr_errors = snmp.get("InAddrErrors", 0)
    in_unknown_protos = snmp.get("InUnknownProtos", 0)

    arp_lookups = arp_cache.get("lookups", 0)
    arp_hits = arp_cache.get("hits", 0)
    arp_res_failed = arp_cache.get("res_failed", 0)
    arp_forced_gc = arp_cache.get("forced_gc_runs", 0)
    arp_table_fulls = arp_cache.get("table_fulls", 0)
    arp_unresolved_discards = arp_cache.get("unresolved_discards", 0)

    if arp_table_fulls > 0:
        issues.append(f"ARP cache table full condition detected ({arp_table_fulls} drops)")
        recommendations.append("Increase net.ipv4.neigh.default.gc_thresh3 to accommodate larger neighbor table")

    if arp_forced_gc > 0:
        issues.append(f"ARP cache forced garbage collection triggered ({arp_forced_gc} runs)")
        recommendations.append("Audit network neighbor churn and increase ARP gc_thresh thresholds")

    all_drop_unicast = interfaces.get("all", {}).get("drop_unicast_in_l2_multicast", 0)
    default_drop_unicast = interfaces.get("default", {}).get("drop_unicast_in_l2_multicast", 0)
    all_promote_sec = interfaces.get("all", {}).get("promote_secondaries", 0)
    default_promote_sec = interfaces.get("default", {}).get("promote_secondaries", 0)
    all_arp_evict = interfaces.get("all", {}).get("arp_evict_nocarrier", 1)

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "DEGRADED"

    return {
        "pattern": 293,
        "name": "ipv4_l2_policy",
        "description": "Host Network IPv4 L2 Multicast Unicast Drop, Secondary Promotion & Carrier Eviction Guard",
        "status": status,
        "healthy": healthy,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "interfaces_audited": len(interfaces),
        "all_drop_unicast_in_l2_multicast": all_drop_unicast,
        "default_drop_unicast_in_l2_multicast": default_drop_unicast,
        "all_promote_secondaries": all_promote_sec,
        "default_promote_secondaries": default_promote_sec,
        "all_arp_evict_nocarrier": all_arp_evict,
        "in_discards": in_discards,
        "in_addr_errors": in_addr_errors,
        "in_unknown_protos": in_unknown_protos,
        "arp_lookups": arp_lookups,
        "arp_hits": arp_hits,
        "arp_res_failed": arp_res_failed,
        "arp_forced_gc_runs": arp_forced_gc,
        "arp_table_fulls": arp_table_fulls,
        "arp_unresolved_discards": arp_unresolved_discards,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IPv4 L2 Multicast Unicast Drop, Secondary Promotion & Carrier Eviction Guard"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--conf-dir", default=CONF_IPV4_BASE, help="Path to IPv4 conf sysctl directory")
    parser.add_argument("--snmp-path", default=PROC_SNMP, help="Path to snmp stats file")
    parser.add_argument("--arp-cache-path", default=PROC_ARP_CACHE, help="Path to arp_cache stats file")
    args = parser.parse_args()

    result = evaluate_ipv4_l2_policy(
        conf_dir=args.conf_dir,
        snmp_path=args.snmp_path,
        arp_cache_path=args.arp_cache_path,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] {result['description']}")
        print(f"  Interfaces Audited: {result['interfaces_audited']}")
        print(f"  Drop Unicast L2 Mcast (all): {result['all_drop_unicast_in_l2_multicast']}, Default: {result['default_drop_unicast_in_l2_multicast']}")
        print(f"  Promote Secondaries (all): {result['all_promote_secondaries']}, Default: {result['default_promote_secondaries']}")
        print(f"  ARP Evict No Carrier (all): {result['all_arp_evict_nocarrier']}")
        print(f"  Inbound Discards: {result['in_discards']}, Inbound Address Errors: {result['in_addr_errors']}")
        print(f"  ARP Lookups: {result['arp_lookups']}, Hits: {result['arp_hits']}, Failed: {result['arp_res_failed']}")
        print(f"  ARP Table Fulls: {result['arp_table_fulls']}, Forced GC Runs: {result['arp_forced_gc_runs']}")
        if result["issues"]:
            print("  Issues:")
            for issue in result["issues"]:
                print(f"    - {issue}")

    return 0 if result["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
