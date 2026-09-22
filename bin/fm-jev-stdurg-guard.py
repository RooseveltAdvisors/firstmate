#!/usr/bin/env python3
"""
bin/fm-jev-stdurg-guard.py - Host Network TCP Urgent Pointer Interpretation & Out-of-Band Data Guard (Pattern 180)

Audits kernel TCP urgent pointer interpretation (tcp_stdurg) alongside TCP error/checksum counters
to verify RFC 793 BSD standard interoperability and prevent out-of-band data offset corruption across
legacy telnet, streaming proxies, and agent communication sockets.
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


def parse_snmp_tcp(path: str = "/proc/net/snmp") -> Dict[str, int]:
    counters: Dict[str, int] = {}
    if not os.path.exists(path):
        return counters
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
        for i in range(len(lines)):
            line = lines[i].strip()
            if line.startswith("Tcp: ") and i + 1 < len(lines):
                next_line = lines[i + 1].strip()
                if next_line.startswith("Tcp: "):
                    headers = line.split()[1:]
                    values = next_line.split()[1:]
                    for h, v in zip(headers, values):
                        try:
                            counters[h] = int(v)
                        except ValueError:
                            pass
                    break
    except Exception as e:
        print(f"Warning: unable to parse snmp {path}: {e}", file=sys.stderr)
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
        print(f"Warning: unable to parse netstat {path}: {e}", file=sys.stderr)
    return counters


def audit_stdurg(
    stdurg_file: str = "/proc/sys/net/ipv4/tcp_stdurg",
    snmp_file: str = "/proc/net/snmp",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    stdurg = read_sysctl_int(stdurg_file)
    snmp_tcp = parse_snmp_tcp(snmp_file)
    netstat = parse_netstat(netstat_file)

    in_csum_errors = snmp_tcp.get("InCsumErrors", 0)
    in_errs = snmp_tcp.get("InErrs", 0)
    estab_resets = snmp_tcp.get("EstabResets", 0)
    retrans_segs = snmp_tcp.get("RetransSegs", 0)
    tcp_abort_on_data = netstat.get("TCPAbortOnData", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    if stdurg == -1:
        status = "WARNING"
        healthy = False
        issues.append("Unable to read net.ipv4.tcp_stdurg sysctl")
        stdurg_desc = "Unknown"
    elif stdurg == 1:
        status = "WARNING"
        healthy = False
        issues.append("Non-standard RFC 1122 urgent pointer enabled (tcp_stdurg=1); BSD socket interoperability risk")
        stdurg_desc = "RFC 1122 interpretation (urg ptr points to last byte of urgent data)"
    else:
        stdurg_desc = "BSD interpretation (urg ptr points to first byte after urgent data)"

    if in_csum_errors > 100:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated TCP checksum errors: {in_csum_errors}")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_stdurg": stdurg,
        "tcp_stdurg_desc": stdurg_desc,
        "in_csum_errors": in_csum_errors,
        "in_errs": in_errs,
        "estab_resets": estab_resets,
        "retrans_segs": retrans_segs,
        "tcp_abort_on_data": tcp_abort_on_data,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_stdurg": stdurg,
        },
        "counters": {
            "InCsumErrors": in_csum_errors,
            "InErrs": in_errs,
            "EstabResets": estab_resets,
            "RetransSegs": retrans_segs,
            "TCPAbortOnData": tcp_abort_on_data,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Urgent Pointer Interpretation & Out-of-Band Data Guard (Pattern 180)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_stdurg()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Urgent Pointer Interpretation Guard (Pattern 180) - Status: {s['status']}")
    print(f"  tcp_stdurg:                   {s['tcp_stdurg']} ({s['tcp_stdurg_desc']})")
    print(f"  TCP Checksum Errors:          {s['in_csum_errors']}")
    print(f"  TCP In Errors:                {s['in_errs']}")
    print(f"  TCP Established Resets:       {s['estab_resets']}")
    print(f"  TCP Aborts On Unread Data:    {s['tcp_abort_on_data']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
