#!/usr/bin/env python3
"""
bin/fm-jev-ipv4-shared-media-guard.py - Linux IPv4 Shared Media, Secure Redirects & BOOTP Relay Guard (Pattern 297 / Pattern 435)

Audits Linux kernel IPv4 shared media and secure redirect policies across interfaces:
  - /proc/sys/net/ipv4/conf/*/shared_media: Send redirects if alternative route is on same network (RFC 1620)
  - /proc/sys/net/ipv4/conf/*/secure_redirects: Accept ICMP redirects only for gateways in default list (RFC 1122)
  - /proc/sys/net/ipv4/conf/*/bootp_relay: Accept BOOTP/DHCP packets with non-zero broadcast flag (RFC 1542)
  - /proc/sys/net/ipv4/conf/*/proxy_arp_pvlan: Private VLAN proxy ARP (0=disabled, 1=enabled)
  - /proc/net/snmp: ICMP InRedirects, OutRedirects, IP InDiscards, OutDiscards, InNoRoutes, OutNoRoutes

Invariants:
  - secure_redirects must be 1 on physical/default interfaces to protect against rogue redirect spoofing.
  - bootp_relay must be 0 to prevent unauthenticated DHCP relaying.
  - Fail-open: graceful fallback when sysctl paths or /proc/net/snmp are restricted.
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


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content and (content.split()[0].lstrip("-").isdigit()) else default
    except (ValueError, OSError, IndexError):
        return default


def parse_snmp_counters(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {
        "InRedirects": 0,
        "OutRedirects": 0,
        "InDiscards": 0,
        "OutDiscards": 0,
        "InNoRoutes": 0,
        "OutNoRoutes": 0,
    }
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        for i in range(0, len(lines) - 1, 2):
            header = lines[i].split()
            values = lines[i + 1].split()
            if len(header) >= 2 and len(values) >= 2:
                prefix = header[0].rstrip(":")
                if prefix in ("Ip", "Icmp"):
                    for k, v in zip(header[1:], values[1:]):
                        if k in metrics:
                            try:
                                metrics[k] = int(v)
                            except ValueError:
                                pass
    except Exception:
        pass
    return metrics


def evaluate_ipv4_shared_media(
    conf_dir: str = CONF_IPV4_BASE,
    snmp_path: str = PROC_SNMP,
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

                sm = read_sysctl_int(os.path.join(iface_dir, "shared_media"), default=-1)
                sr = read_sysctl_int(os.path.join(iface_dir, "secure_redirects"), default=-1)
                br = read_sysctl_int(os.path.join(iface_dir, "bootp_relay"), default=-1)
                pv = read_sysctl_int(os.path.join(iface_dir, "proxy_arp_pvlan"), default=-1)

                if sr != -1 or sm != -1:
                    interfaces[entry] = {
                        "shared_media": sm,
                        "secure_redirects": sr,
                        "bootp_relay": br,
                        "proxy_arp_pvlan": pv,
                    }

                    if sr == 0 and entry in ("all", "default", "enp7s0", "wlp8s0", "eth0"):
                        issues.append(f"Insecure ICMP redirects allowed on {entry} (secure_redirects=0)")
                        recommendations.append(f"Set /proc/sys/net/ipv4/conf/{entry}/secure_redirects to 1")

                    if br == 1:
                        issues.append(f"Unintended BOOTP relay enabled on {entry} (bootp_relay=1)")
                        recommendations.append(f"Set /proc/sys/net/ipv4/conf/{entry}/bootp_relay to 0")

                    if sr not in (-1, 0, 1):
                        issues.append(f"Invalid secure_redirects value on {entry} ({sr})")

                    if sm not in (-1, 0, 1):
                        issues.append(f"Invalid shared_media value on {entry} ({sm})")

                    if pv not in (-1, 0, 1):
                        issues.append(f"Invalid proxy_arp_pvlan value on {entry} ({pv})")
        except OSError:
            pass

    snmp_metrics = parse_snmp_counters(snmp_path)
    all_sr = interfaces.get("all", {}).get("secure_redirects", 1)
    default_sr = interfaces.get("default", {}).get("secure_redirects", 1)
    all_sm = interfaces.get("all", {}).get("shared_media", 1)
    default_sm = interfaces.get("default", {}).get("shared_media", 1)
    all_br = interfaces.get("all", {}).get("bootp_relay", 0)
    default_br = interfaces.get("default", {}).get("bootp_relay", 0)
    all_pv = interfaces.get("all", {}).get("proxy_arp_pvlan", 0)
    default_pv = interfaces.get("default", {}).get("proxy_arp_pvlan", 0)

    status = "WARNING" if issues else "HEALTHY"

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "pattern": 297,
        "name": "ipv4_shared_media",
        "status": status,
        "healthy": len(issues) == 0,
        "interfaces_audited": len(interfaces),
        "all_secure_redirects": all_sr,
        "default_secure_redirects": default_sr,
        "all_shared_media": all_sm,
        "default_shared_media": default_sm,
        "all_bootp_relay": all_br,
        "default_bootp_relay": default_br,
        "all_proxy_arp_pvlan": all_pv,
        "default_proxy_arp_pvlan": default_pv,
        "in_redirects": snmp_metrics["InRedirects"],
        "out_redirects": snmp_metrics["OutRedirects"],
        "in_discards": snmp_metrics["InDiscards"],
        "out_discards": snmp_metrics["OutDiscards"],
        "in_no_routes": snmp_metrics["InNoRoutes"],
        "out_no_routes": snmp_metrics["OutNoRoutes"],
        "interfaces": interfaces,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Audit Linux IPv4 Shared Media, Secure Redirects & BOOTP Relay Policy (Pattern 297 / Pattern 435)"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--conf-dir", default=CONF_IPV4_BASE, help="Path to /proc/sys/net/ipv4/conf")
    parser.add_argument("--snmp-file", default=PROC_SNMP, help="Path to /proc/net/snmp")
    args = parser.parse_args()

    data = evaluate_ipv4_shared_media(
        conf_dir=args.conf_dir,
        snmp_path=args.snmp_file,
    )

    if args.json:
        print(json.dumps(data, indent=2))
    else:
        print(f"[{data['status']}] Pattern 297 - IPv4 Shared Media & Secure Redirect Guard")
        print(f"  Interfaces Audited: {data['interfaces_audited']}")
        print(f"  All Secure Redirects: {data['all_secure_redirects']} (RFC 1122 default: 1)")
        print(f"  Default Secure Redirects: {data['default_secure_redirects']}")
        print(f"  All Shared Media: {data['all_shared_media']} (RFC 1620 default: 1)")
        print(f"  Default Shared Media: {data['default_shared_media']}")
        print(f"  All BOOTP Relay: {data['all_bootp_relay']} (default: 0)")
        print(f"  Default BOOTP Relay: {data['default_bootp_relay']}")
        print(f"  All PVLAN Proxy ARP: {data['all_proxy_arp_pvlan']} (default: 0)")
        print(f"  Default PVLAN Proxy ARP: {data['default_proxy_arp_pvlan']}")
        print(f"  Inbound Redirects: {data['in_redirects']:,}")
        print(f"  Outbound Redirects: {data['out_redirects']:,}")
        print(f"  Inbound Discards: {data['in_discards']:,}")
        print(f"  Outbound Discards: {data['out_discards']:,}")
        print(f"  Inbound No Routes: {data['in_no_routes']:,}")
        print(f"  Outbound No Routes: {data['out_no_routes']:,}")
        if data["issues"]:
            print("  Issues:")
            for issue in data["issues"]:
                print(f"    - {issue}")
        else:
            print("  Issues: None (100% compliant)")

    sys.exit(0 if data["healthy"] else 1)


if __name__ == "__main__":
    main()
