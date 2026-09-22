#!/usr/bin/env python3
"""
bin/fm-jev-ulp-guard.py - Host Network TCP Upper Layer Protocol (ULP) & TLS Socket Offload Guard (Pattern 182)

Audits kernel TCP Upper Layer Protocol registrations (tcp_available_ulp) alongside in-kernel TLS (kTLS)
runtime statistics (/proc/net/tls_stat) to verify zero-copy socket crypto acceleration readiness, ensure
mptcp and tls ULP availability, and detect kTLS cryptographic decryption or re-keying failures across
high-throughput agent streaming connections.
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List


def read_sysctl_str(path: str) -> str:
    if not os.path.exists(path):
        return ""
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception as e:
        print(f"Warning: unable to read {path}: {e}", file=sys.stderr)
        return ""


def parse_tls_stat(path: str = "/proc/net/tls_stat") -> Dict[str, int]:
    counters: Dict[str, int] = {}
    if not os.path.exists(path):
        return counters
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 2:
                    try:
                        counters[parts[0]] = int(parts[1])
                    except ValueError:
                        pass
    except Exception as e:
        print(f"Warning: unable to parse {path}: {e}", file=sys.stderr)
    return counters


def audit_ulp(
    ulp_file: str = "/proc/sys/net/ipv4/tcp_available_ulp",
    tls_stat_file: str = "/proc/net/tls_stat",
) -> Dict[str, Any]:
    ulp_raw = read_sysctl_str(ulp_file)
    available_ulps: List[str] = ulp_raw.split() if ulp_raw else []
    tls_stat = parse_tls_stat(tls_stat_file)

    curr_tx_sw = tls_stat.get("TlsCurrTxSw", 0)
    curr_rx_sw = tls_stat.get("TlsCurrRxSw", 0)
    curr_tx_device = tls_stat.get("TlsCurrTxDevice", 0)
    curr_rx_device = tls_stat.get("TlsCurrRxDevice", 0)
    total_tx_sw = tls_stat.get("TlsTxSw", 0)
    total_rx_sw = tls_stat.get("TlsRxSw", 0)
    decrypt_errors = tls_stat.get("TlsDecryptError", 0)
    decrypt_retries = tls_stat.get("TlsDecryptRetry", 0)
    rx_rekey_errors = tls_stat.get("TlsRxRekeyError", 0)
    tx_rekey_errors = tls_stat.get("TlsTxRekeyError", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    if not ulp_raw:
        status = "WARNING"
        healthy = False
        issues.append("Unable to read net.ipv4.tcp_available_ulp sysctl")
    else:
        if "tls" not in available_ulps:
            status = "WARNING"
            healthy = False
            issues.append("Kernel TLS (tls) ULP is not registered in tcp_available_ulp")
        if "mptcp" not in available_ulps:
            status = "WARNING"
            healthy = False
            issues.append("Multipath TCP (mptcp) ULP is not registered in tcp_available_ulp")

    if decrypt_errors > 0:
        status = "WARNING"
        healthy = False
        issues.append(f"Kernel TLS decryption errors detected: {decrypt_errors}")

    if rx_rekey_errors > 0 or tx_rekey_errors > 0:
        status = "WARNING"
        healthy = False
        issues.append(f"Kernel TLS re-keying errors detected: rx={rx_rekey_errors}, tx={tx_rekey_errors}")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_available_ulp": ulp_raw,
        "available_ulps": available_ulps,
        "has_tls_ulp": "tls" in available_ulps,
        "has_mptcp_ulp": "mptcp" in available_ulps,
        "active_ktls_sw_sessions": curr_tx_sw + curr_rx_sw,
        "active_ktls_device_sessions": curr_tx_device + curr_rx_device,
        "decrypt_errors": decrypt_errors,
        "rekey_errors": rx_rekey_errors + tx_rekey_errors,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_available_ulp": ulp_raw,
        },
        "tls_stat": {
            "TlsCurrTxSw": curr_tx_sw,
            "TlsCurrRxSw": curr_rx_sw,
            "TlsCurrTxDevice": curr_tx_device,
            "TlsCurrRxDevice": curr_rx_device,
            "TlsTxSw": total_tx_sw,
            "TlsRxSw": total_rx_sw,
            "TlsDecryptError": decrypt_errors,
            "TlsDecryptRetry": decrypt_retries,
            "TlsRxRekeyError": rx_rekey_errors,
            "TlsTxRekeyError": tx_rekey_errors,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Upper Layer Protocol (ULP) & TLS Socket Offload Guard (Pattern 182)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_ulp()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Upper Layer Protocol (ULP) Guard (Pattern 182) - Status: {s['status']}")
    print(f"  tcp_available_ulp:            {s['tcp_available_ulp']}")
    print(f"  kTLS Support (tls):           {'Available' if s['has_tls_ulp'] else 'Missing'}")
    print(f"  MPTCP Support (mptcp):        {'Available' if s['has_mptcp_ulp'] else 'Missing'}")
    print(f"  Active kTLS SW Sessions:      {s['active_ktls_sw_sessions']}")
    print(f"  Active kTLS Device Sessions:  {s['active_ktls_device_sessions']}")
    print(f"  kTLS Decrypt Errors:          {s['decrypt_errors']}")
    print(f"  kTLS Re-keying Errors:        {s['rekey_errors']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
