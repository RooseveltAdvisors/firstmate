#!/usr/bin/env python3
"""
bin/fm-jev-tos-reflect-guard.py - Host Network TCP DSCP / Type-of-Service Reflection Guard (Pattern 176)

Audits kernel TCP Type-of-Service (ToS) reflection (tcp_reflect_tos) and IP default TTL
alongside IP header and traffic class delivery counters (TCPDelivered, TCPDeliveredCE,
InHdrErrors, InDiscards) to ensure high-priority agent RPC traffic maintains DiffServ/QoS
prioritization across intermediate routing hops without class remark degradation.
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict


def read_sysctl_int(path: str) -> int:
    if not os.path.exists(path):
        return -1
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception as e:
        print(f"Warning: unable to read {path}: {e}", file=sys.stderr)
        return -1


def parse_snmp_ip(path: str = "/proc/net/snmp") -> Dict[str, int]:
    counters: Dict[str, int] = {}
    if not os.path.exists(path):
        return counters
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
        for i in range(0, len(lines), 2):
            if i + 1 >= len(lines):
                break
            headers = lines[i].split()
            values = lines[i + 1].split()
            if len(headers) == len(values) and headers[0] == "Ip:":
                for h, v in zip(headers[1:], values[1:]):
                    try:
                        counters[h] = int(v)
                    except ValueError:
                        pass
    except Exception as e:
        print(f"Warning: unable to parse {path}: {e}", file=sys.stderr)
    return counters


def parse_netstat(path: str = "/proc/net/netstat") -> Dict[str, int]:
    counters: Dict[str, int] = {}
    if not os.path.exists(path):
        return counters
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
        for i in range(0, len(lines), 2):
            if i + 1 >= len(lines):
                break
            headers = lines[i].split()
            values = lines[i + 1].split()
            if len(headers) == len(values) and headers[0] == values[0]:
                for h, v in zip(headers[1:], values[1:]):
                    try:
                        counters[h] = int(v)
                    except ValueError:
                        pass
    except Exception as e:
        print(f"Warning: unable to parse {path}: {e}", file=sys.stderr)
    return counters


def audit_tos_reflect(
    tos_reflect_file: str = "/proc/sys/net/ipv4/tcp_reflect_tos",
    default_ttl_file: str = "/proc/sys/net/ipv4/ip_default_ttl",
    snmp_file: str = "/proc/net/snmp",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    reflect_tos = read_sysctl_int(tos_reflect_file)
    default_ttl = read_sysctl_int(default_ttl_file)
    ip_snmp = parse_snmp_ip(snmp_file)
    netstat = parse_netstat(netstat_file)

    in_receives = ip_snmp.get("InReceives", 0)
    in_delivers = ip_snmp.get("InDelivers", 0)
    in_discards = ip_snmp.get("InDiscards", 0)
    in_hdr_errors = ip_snmp.get("InHdrErrors", 0)
    out_discards = ip_snmp.get("OutDiscards", 0)

    delivered = netstat.get("TCPDelivered", 0)
    delivered_ce = netstat.get("TCPDeliveredCE", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    if in_hdr_errors > 100:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated IP header errors: {in_hdr_errors}")

    if in_receives > 0 and in_discards / in_receives > 0.05:
        status = "WARNING"
        healthy = False
        issues.append(f"High IP discard ratio: {in_discards} / {in_receives}")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_reflect_tos": reflect_tos,
        "ip_default_ttl": default_ttl,
        "ip_in_receives": in_receives,
        "ip_in_delivers": in_delivers,
        "ip_in_discards": in_discards,
        "ip_in_hdr_errors": in_hdr_errors,
        "ip_out_discards": out_discards,
        "tcp_delivered": delivered,
        "tcp_delivered_ce": delivered_ce,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_reflect_tos": reflect_tos,
            "ip_default_ttl": default_ttl,
        },
        "counters": {
            "InReceives": in_receives,
            "InDelivers": in_delivers,
            "InDiscards": in_discards,
            "InHdrErrors": in_hdr_errors,
            "OutDiscards": out_discards,
            "TCPDelivered": delivered,
            "TCPDeliveredCE": delivered_ce,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP DSCP / Type-of-Service Reflection Guard (Pattern 176)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_tos_reflect()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP ToS / DSCP Reflection Guard (Pattern 176) - Status: {s['status']}")
    print(f"  tcp_reflect_tos:              {s['tcp_reflect_tos']} (0 = off, 1 = reflected)")
    print(f"  ip_default_ttl:               {s['ip_default_ttl']} hops")
    print(f"  IP In Receives:               {s['ip_in_receives']}")
    print(f"  IP In Delivers:               {s['ip_in_delivers']}")
    print(f"  IP In Discards:               {s['ip_in_discards']}")
    print(f"  IP In Header Errors:          {s['ip_in_hdr_errors']}")
    print(f"  TCP Delivered Segments:       {s['tcp_delivered']}")
    print(f"  TCP Delivered CE Segments:    {s['tcp_delivered_ce']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
