#!/usr/bin/env python3
"""
bin/fm-jev-csprng-guard.py - Linux Kernel CSPRNG & Entropy Pool Health Guard (Pattern 314 / Pattern 452)

Audits Linux kernel Cryptographically Secure Pseudorandom Number Generator (CSPRNG)
entropy availability (/proc/sys/kernel/random/entropy_avail), entropy pool capacity
(/proc/sys/kernel/random/poolsize), urandom reseed interval (/proc/sys/kernel/random/urandom_min_reseed_secs),
write wakeup threshold (/proc/sys/kernel/random/write_wakeup_threshold), and boot identifier
(/proc/sys/kernel/random/boot_id) to detect entropy starvation, getrandom() blocking stalls,
and cryptographic degradation under multi-agent token generation, TLS session handshakes,
and Agent Vault secret brokering.

Invariants:
  - Warn when entropy available < 25%, critical when < 10% or 0 bits.
  - Warn when poolsize < 128 bits.
  - Warn when urandom_min_reseed_secs > 3600s.
  - Fail-open: graceful fallback when sysctl pseudo-files are restricted.
  - Bounded fast execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

PROC_RANDOM = "/proc/sys/kernel/random"

DEFAULT_WARN_MIN_ENTROPY_PCT = 25.0
DEFAULT_CRIT_MIN_ENTROPY_PCT = 10.0
DEFAULT_MIN_POOLSIZE = 128


def parse_int_sysctl(path: Path, default: int = 0) -> int:
    if not path.is_file():
        return default
    try:
        content = path.read_text(encoding="utf-8", errors="replace").strip()
        parts = content.split()
        return int(parts[0]) if parts and parts[0].lstrip("-").isdigit() else default
    except (ValueError, OSError, IndexError):
        return default


def parse_str_sysctl(path: Path, default: str = "") -> str:
    if not path.is_file():
        return default
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except (OSError, UnicodeDecodeError):
        return default


def evaluate_csprng(
    random_dir: str = PROC_RANDOM,
    warn_min_entropy_pct: float = DEFAULT_WARN_MIN_ENTROPY_PCT,
    crit_min_entropy_pct: float = DEFAULT_CRIT_MIN_ENTROPY_PCT,
    min_poolsize: int = DEFAULT_MIN_POOLSIZE,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    p = Path(random_dir)
    entropy_avail = parse_int_sysctl(p / "entropy_avail", default=256)
    poolsize = parse_int_sysctl(p / "poolsize", default=256)
    reseed_secs = parse_int_sysctl(p / "urandom_min_reseed_secs", default=60)
    wakeup_thresh = parse_int_sysctl(p / "write_wakeup_threshold", default=256)
    boot_id = parse_str_sysctl(p / "boot_id", default="")

    entropy_pct = (entropy_avail / poolsize * 100.0) if poolsize > 0 else 0.0

    if poolsize < min_poolsize:
        status = "WARNING"
        issues.append(
            f"Kernel entropy poolsize is constrained ({poolsize} bits < {min_poolsize} bits)"
        )
        recommendations.append(f"Ensure kernel entropy pool size is configured >= {min_poolsize} bits")

    if entropy_avail == 0:
        status = "CRITICAL"
        issues.append(
            f"Kernel CSPRNG entropy pool is completely exhausted (0/{poolsize} bits); "
            "blocking getrandom() and /dev/random operations will stall"
        )
        recommendations.append("Investigate high entropy-consuming processes or feed hardware RNG via rngd")
    elif entropy_pct < crit_min_entropy_pct:
        status = "CRITICAL"
        issues.append(
            f"Kernel CSPRNG entropy pool critical ({entropy_pct:.1f}% < {crit_min_entropy_pct}%, "
            f"{entropy_avail}/{poolsize} bits); imminent risk of cryptographic stalling"
        )
        recommendations.append("Audit entropy consumption or enable virtio-rng / haveged")
    elif entropy_pct < warn_min_entropy_pct:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"Kernel CSPRNG entropy pool low ({entropy_pct:.1f}% < {warn_min_entropy_pct}%, "
            f"{entropy_avail}/{poolsize} bits)"
        )
        recommendations.append("Monitor CSPRNG entropy depletion rates during high agent concurrency")

    if reseed_secs > 3600:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"urandom_min_reseed_secs is abnormally elevated ({reseed_secs}s > 3600s); infrequent CSPRNG re-seeding"
        )
        recommendations.append("Reset sysctl kernel.random.urandom_min_reseed_secs to 60")

    healthy = (status == "HEALTHY")
    is_entropy_sufficient = (entropy_pct >= warn_min_entropy_pct) and (entropy_avail > 0)

    return {
        "pattern": 314,
        "name": "csprng",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": healthy,
        "is_entropy_sufficient": is_entropy_sufficient,
        "entropy_avail": entropy_avail,
        "poolsize": poolsize,
        "entropy_ratio_pct": round(entropy_pct, 2),
        "urandom_min_reseed_secs": reseed_secs,
        "write_wakeup_threshold": wakeup_thresh,
        "boot_id": boot_id,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Linux kernel CSPRNG entropy pool and random generator health."
    )
    parser.add_argument("--json", action="store_true", help="Output telemetry in JSON format")
    parser.add_argument("--random-dir", default=PROC_RANDOM, help=f"Path to /proc/sys/kernel/random (default: {PROC_RANDOM})")
    parser.add_argument("--warn-min-entropy-pct", type=float, default=DEFAULT_WARN_MIN_ENTROPY_PCT, help="Min entropy warning threshold %%")
    parser.add_argument("--crit-min-entropy-pct", type=float, default=DEFAULT_CRIT_MIN_ENTROPY_PCT, help="Min entropy critical threshold %%")
    parser.add_argument("--min-poolsize", type=int, default=DEFAULT_MIN_POOLSIZE, help="Min poolsize bits")

    args = parser.parse_args()

    result = evaluate_csprng(
        random_dir=args.random_dir,
        warn_min_entropy_pct=args.warn_min_entropy_pct,
        crit_min_entropy_pct=args.crit_min_entropy_pct,
        min_poolsize=args.min_poolsize,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        status_symbol = "✓" if result["healthy"] else "✗"
        print(f"[{status_symbol}] Pattern 314 (csprng): {result['status']}")
        print(
            f"  Entropy: {result['entropy_avail']} / {result['poolsize']} bits ({result['entropy_ratio_pct']}%) | "
            f"Wakeup Threshold: {result['write_wakeup_threshold']} bits"
        )
        print(
            f"  Reseed Secs: {result['urandom_min_reseed_secs']}s | Boot ID: {result['boot_id']}"
        )
        if result["issues"]:
            print("  Issues:")
            for iss in result["issues"]:
                print(f"    - {iss}")
        if result["recommendations"]:
            print("  Recommendations:")
            for rec in result["recommendations"]:
                print(f"    - {rec}")

    return 0 if result["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
