#!/usr/bin/env python3
"""
bin/fm-jev-ktls-guard.py - Host Network Kernel TLS (kTLS) Decryption Error & Rekeying Guard (Pattern 225)

Audits Linux kernel TLS (kTLS) subsystem statistics from /proc/net/tls_stat:
  - Software vs Hardware TLS socket sessions (TlsCurrTxSw, TlsCurrRxSw, TlsCurrTxDevice, TlsCurrRxDevice)
  - Cryptographic packet volume (TlsTxSw, TlsRxSw, TlsTxDevice, TlsRxDevice)
  - TLS Decryption errors and retries (TlsDecryptError, TlsDecryptRetry)
  - Hardware device resynchronizations (TlsRxDeviceResync)
  - Rekeying events and negotiation failures (TlsRxRekeyOk, TlsRxRekeyError, TlsTxRekeyOk, TlsTxRekeyError, TlsRxRekeyReceived)
  - Padding integrity violations (TlsRxNoPadViolation)

Detects kernel TLS corruption, cipher suite desynchronization, key rotation failures,
and hardware NIC TLS offload errors before encrypted agent tunnels or secure RPC connections drop.

Invariants:
  - Read-only diagnostics. Safe, passive, and non-destructive.
  - Fail-open: graceful fallback when /proc/net/tls_stat is missing or restricted.
  - Bounded sub-millisecond execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Optional


def parse_tls_stat_file(path: str) -> Dict[str, int]:
    """Parse /proc/net/tls_stat format (key whitespace value)."""
    stats: Dict[str, int] = {}
    if not os.path.exists(path):
        return stats

    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                parts = line.split()
                if len(parts) >= 2:
                    k = parts[0]
                    try:
                        v = int(parts[1])
                        stats[k] = v
                    except ValueError:
                        continue
    except Exception:
        pass
    return stats


def audit_ktls(
    stat_path: str = "/proc/net/tls_stat",
    ulp_path: str = "/proc/sys/net/ipv4/tcp_available_ulp",
    warn_error_threshold: int = 10,
    crit_error_threshold: int = 100,
) -> Dict[str, Any]:
    stats = parse_tls_stat_file(stat_path)

    # Check tcp_available_ulp for kTLS kernel support
    ulp_available = False
    ulp_list: List[str] = []
    if os.path.exists(ulp_path):
        try:
            with open(ulp_path, "r", encoding="utf-8") as f:
                ulp_list = f.read().strip().split()
                ulp_available = "tls" in ulp_list
        except Exception:
            pass

    # Extract active socket counts
    curr_tx_sw = stats.get("TlsCurrTxSw", 0)
    curr_rx_sw = stats.get("TlsCurrRxSw", 0)
    curr_tx_dev = stats.get("TlsCurrTxDevice", 0)
    curr_rx_dev = stats.get("TlsCurrRxDevice", 0)
    total_active_sessions = curr_tx_sw + curr_rx_sw + curr_tx_dev + curr_rx_dev

    # Extract traffic counters
    tx_sw = stats.get("TlsTxSw", 0)
    rx_sw = stats.get("TlsRxSw", 0)
    tx_dev = stats.get("TlsTxDevice", 0)
    rx_dev = stats.get("TlsRxDevice", 0)
    total_records = tx_sw + rx_sw + tx_dev + rx_dev

    # Extract errors and anomalies
    decrypt_errors = stats.get("TlsDecryptError", 0)
    decrypt_retries = stats.get("TlsDecryptRetry", 0)
    rx_rekey_errors = stats.get("TlsRxRekeyError", 0)
    tx_rekey_errors = stats.get("TlsTxRekeyError", 0)
    total_rekey_errors = rx_rekey_errors + tx_rekey_errors
    device_resyncs = stats.get("TlsRxDeviceResync", 0)
    pad_violations = stats.get("TlsRxNoPadViolation", 0)

    # Extract successful rekeys
    rx_rekey_ok = stats.get("TlsRxRekeyOk", 0)
    tx_rekey_ok = stats.get("TlsTxRekeyOk", 0)
    rekey_received = stats.get("TlsRxRekeyReceived", 0)

    issues: List[str] = []
    status = "HEALTHY"

    if decrypt_errors >= crit_error_threshold:
        status = "CRITICAL"
        issues.append(f"High kTLS decryption errors: {decrypt_errors} (threshold: {crit_error_threshold})")
    elif decrypt_errors >= warn_error_threshold:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Elevated kTLS decryption errors: {decrypt_errors} (threshold: {warn_error_threshold})")

    if total_rekey_errors >= crit_error_threshold:
        status = "CRITICAL"
        issues.append(f"High kTLS rekeying failures: {total_rekey_errors} (RX: {rx_rekey_errors}, TX: {tx_rekey_errors})")
    elif total_rekey_errors >= warn_error_threshold:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Elevated kTLS rekeying failures: {total_rekey_errors} (RX: {rx_rekey_errors}, TX: {tx_rekey_errors})")

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
        "status": status,
        "healthy": (status == "HEALTHY"),
        "ulp_available": ulp_available,
        "ulp_list": ulp_list,
        "total_active_sessions": total_active_sessions,
        "active_sessions": {
            "tx_software": curr_tx_sw,
            "rx_software": curr_rx_sw,
            "tx_device_offload": curr_tx_dev,
            "rx_device_offload": curr_rx_dev,
        },
        "traffic": {
            "tx_software_records": tx_sw,
            "rx_software_records": rx_sw,
            "tx_device_records": tx_dev,
            "rx_device_records": rx_dev,
            "total_records": total_records,
        },
        "integrity": {
            "decrypt_errors": decrypt_errors,
            "decrypt_retries": decrypt_retries,
            "rx_rekey_errors": rx_rekey_errors,
            "tx_rekey_errors": tx_rekey_errors,
            "total_rekey_errors": total_rekey_errors,
            "device_resyncs": device_resyncs,
            "pad_violations": pad_violations,
        },
        "rekey_activity": {
            "rx_rekey_ok": rx_rekey_ok,
            "tx_rekey_ok": tx_rekey_ok,
            "rekey_received": rekey_received,
        },
        "raw_stats_count": len(stats),
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Host Network Kernel TLS (kTLS) Guard")
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--stat-path", default="/proc/net/tls_stat", help="Path to tls_stat file")
    parser.add_argument("--ulp-path", default="/proc/sys/net/ipv4/tcp_available_ulp", help="Path to tcp_available_ulp")
    parser.add_argument("--warn-error", type=int, default=10, help="Warning threshold for decryption or rekey errors")
    parser.add_argument("--crit-error", type=int, default=100, help="Critical threshold for decryption or rekey errors")

    args = parser.parse_args()
    report = audit_ktls(
        stat_path=args.stat_path,
        ulp_path=args.ulp_path,
        warn_error_threshold=args.warn_error,
        crit_error_threshold=args.crit_error,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        status = report["status"]
        sessions = report["total_active_sessions"]
        records = report["traffic"]["total_records"]
        dec_err = report["integrity"]["decrypt_errors"]
        rekey_err = report["integrity"]["total_rekey_errors"]
        ulp = "yes" if report["ulp_available"] else "no"

        print(f"kTLS Guard: {status} | ULP Support: {ulp} | Active Sessions: {sessions} | Records: {records} | Decrypt Errors: {dec_err} | Rekey Errors: {rekey_err}")
        if report["issues"]:
            for issue in report["issues"]:
                print(f"  - ISSUE: {issue}")

    return 0 if report["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
