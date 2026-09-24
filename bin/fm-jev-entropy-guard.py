#!/usr/bin/env python3
"""
fm-jev-entropy-guard.py - Jev Multi-Agent Kernel Entropy Pool & Hardware RNG Depletion Guard (Pattern 81)

Audits Linux kernel entropy pool capacity (/proc/sys/kernel/random/entropy_avail), RNG pool size (/proc/sys/kernel/random/poolsize),
and non-blocking CSPRNG readiness (os.getrandom) to detect entropy starvation. Prevents TLS handshake latency spikes,
crypto key generation stalls, and session token generation freezes during high-concurrency multi-agent orchestration.

Invariants:
  - Read-only diagnostics. Non-destructive.
  - Fail-open: graceful fallback on systems with non-standard procfs.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

DEFAULT_WARN_ENTROPY_RATIO = 0.25  # Warning if entropy < 25% of poolsize
DEFAULT_CRIT_ENTROPY_RATIO = 0.10  # Critical if entropy < 10% of poolsize

SYS_ENTROPY_AVAIL = "/proc/sys/kernel/random/entropy_avail"
SYS_POOLSIZE = "/proc/sys/kernel/random/poolsize"
SYS_WRITE_WAKEUP = "/proc/sys/kernel/random/write_wakeup_threshold"
SYS_RESEED_SECS = "/proc/sys/kernel/random/urandom_min_reseed_secs"


def read_int_file(path: str, default: int = 0) -> int:
    """Reads integer from a sysfs/procfs file."""
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r") as f:
            return int(f.read().strip())
    except Exception:
        return default


def probe_csprng(bytes_to_read: int = 32) -> Dict[str, Any]:
    """Tests non-blocking CSPRNG readiness via os.getrandom."""
    try:
        flags = getattr(os, "GRND_NONBLOCK", 0x0001)
        rand_bytes = os.getrandom(bytes_to_read, flags)
        return {
            "status": "ready",
            "bytes_read": len(rand_bytes),
            "non_blocking": True,
        }
    except BlockingIOError:
        return {
            "status": "blocked",
            "bytes_read": 0,
            "non_blocking": False,
        }
    except Exception as e:
        return {
            "status": f"error: {str(e)}",
            "bytes_read": 0,
            "non_blocking": False,
        }


def audit_entropy(
    entropy_avail_path: str = SYS_ENTROPY_AVAIL,
    poolsize_path: str = SYS_POOLSIZE,
    write_wakeup_path: str = SYS_WRITE_WAKEUP,
    reseed_secs_path: str = SYS_RESEED_SECS,
    warn_ratio: float = DEFAULT_WARN_ENTROPY_RATIO,
    crit_ratio: float = DEFAULT_CRIT_ENTROPY_RATIO,
    test_csprng: bool = True,
) -> Dict[str, Any]:
    """Audits kernel entropy availability and CSPRNG readiness."""
    entropy_avail = read_int_file(entropy_avail_path, default=256)
    poolsize = read_int_file(poolsize_path, default=256)
    write_wakeup = read_int_file(write_wakeup_path, default=0)
    reseed_secs = read_int_file(reseed_secs_path, default=0)

    # In modern Linux (5.6+), poolsize is typically 256 bits
    if poolsize <= 0:
        poolsize = 256

    avail_pct = round((entropy_avail / poolsize) * 100.0, 2)
    warn_threshold = int(poolsize * warn_ratio)
    crit_threshold = int(poolsize * crit_ratio)

    csprng_status = probe_csprng() if test_csprng else {"status": "ready", "bytes_read": 32, "non_blocking": True}

    issues: List[str] = []
    status = "HEALTHY"

    if csprng_status["status"] == "blocked":
        status = "CRITICAL"
        issues.append("CSPRNG is blocking: getrandom() raised BlockingIOError (entropy starvation)")
    elif csprng_status["status"].startswith("error"):
        if status == "HEALTHY":
            status = "WARNING"
        issues.append(f"CSPRNG probe error: {csprng_status['status']}")

    if entropy_avail <= crit_threshold:
        status = "CRITICAL"
        issues.append(f"Critical entropy pool depletion: {entropy_avail}/{poolsize} bits ({avail_pct}%)")
    elif entropy_avail <= warn_threshold:
        if status == "HEALTHY":
            status = "WARNING"
        issues.append(f"Elevated entropy pool depletion: {entropy_avail}/{poolsize} bits ({avail_pct}%)")

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "entropy_avail_bits": entropy_avail,
            "poolsize_bits": poolsize,
            "entropy_avail_pct": avail_pct,
            "csprng_status": csprng_status["status"],
            "issues": issues,
        },
        "kernel_random": {
            "write_wakeup_threshold": write_wakeup,
            "urandom_min_reseed_secs": reseed_secs,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Kernel Entropy Pool & Hardware RNG Depletion Guard (Pattern 81)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--warn-ratio", type=float, default=DEFAULT_WARN_ENTROPY_RATIO, help=f"Warning entropy ratio (default {DEFAULT_WARN_ENTROPY_RATIO})")
    parser.add_argument("--crit-ratio", type=float, default=DEFAULT_CRIT_ENTROPY_RATIO, help=f"Critical entropy ratio (default {DEFAULT_CRIT_ENTROPY_RATIO})")
    parser.add_argument("--proc-entropy", type=str, default=SYS_ENTROPY_AVAIL, help="Path to entropy_avail")
    parser.add_argument("--proc-poolsize", type=str, default=SYS_POOLSIZE, help="Path to poolsize")

    args = parser.parse_args()

    result = audit_entropy(
        entropy_avail_path=args.proc_entropy,
        poolsize_path=args.proc_poolsize,
        warn_ratio=args.warn_ratio,
        crit_ratio=args.crit_ratio,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else ("\033[31m" if summary["status"] == "CRITICAL" else "\033[33m")
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Kernel Entropy & RNG Pool Guard (Pattern 81)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    print(f" Entropy Available:      {summary['entropy_avail_bits']} / {summary['poolsize_bits']} bits ({summary['entropy_avail_pct']}%)")
    print(f" CSPRNG Readiness:       {summary['csprng_status']}")

    if summary["issues"]:
        print("\nActive Issues:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nNo entropy starvation, RNG depletion, or CSPRNG blocking detected.")
    print("================================================================================")


if __name__ == "__main__":
    main()
