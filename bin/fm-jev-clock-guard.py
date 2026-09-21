#!/usr/bin/env python3
"""
fm-jev-clock-guard.py - Jev Multi-Agent Host Clock Drift & NTP Synchronization Guard (Pattern 61)

Audits host clock synchronization, NTP stratum, network delay, jitter, and offset via timedatectl.
Prevents cryptographic authentication token expiration bugs, git commit timestamp drift,
and clearinghouse EDI batch submission clock skew rejections.

Invariants:
  - Read-only diagnostics by default. Non-destructive.
  - Fail-open: graceful handling if timesyncd or NTP is unavailable.
  - Bounded fast execution (< 0.3s).
"""

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any, Dict, Optional, Tuple


DEFAULT_MAX_OFFSET_MS = 500.0
DEFAULT_MAX_JITTER_MS = 100.0


def run_cmd(cmd: list[str], timeout: int = 3) -> Tuple[int, str]:
    """Runs a command and returns (returncode, stdout)."""
    try:
        res = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            check=False,
        )
        return res.returncode, res.stdout.strip()
    except Exception as e:
        return 1, str(e)


def parse_offset_ms(val_str: str) -> Optional[float]:
    """Parses offset string like '+2.001ms' or '-15.2us' or '1.5s' into milliseconds."""
    val_str = val_str.strip().lower()
    m = re.match(r"^([+-]?[0-9.]+)\s*(ms|us|s|min)?$", val_str)
    if not m:
        return None
    num = float(m.group(1))
    unit = m.group(2) or "ms"
    if unit == "ms":
        return num
    elif unit == "us":
        return num / 1000.0
    elif unit == "s":
        return num * 1000.0
    elif unit == "min":
        return num * 60000.0
    return num


def audit_clock_sync(
    max_offset_ms: float = DEFAULT_MAX_OFFSET_MS,
    max_jitter_ms: float = DEFAULT_MAX_JITTER_MS,
) -> Dict[str, Any]:
    """Audits system clock and NTP synchronization status."""
    code_show, out_show = run_cmd(["timedatectl", "show"])
    ntp_synced = False
    ntp_enabled = False
    timezone_str = "UTC"

    if code_show == 0:
        for line in out_show.splitlines():
            if line.startswith("NTPSynchronized="):
                ntp_synced = (line.split("=", 1)[1].strip().lower() == "yes")
            elif line.startswith("NTP="):
                ntp_enabled = (line.split("=", 1)[1].strip().lower() == "yes")
            elif line.startswith("Timezone="):
                timezone_str = line.split("=", 1)[1].strip()

    code_sync, out_sync = run_cmd(["timedatectl", "timesync-status"])
    server_str = "unknown"
    offset_ms: Optional[float] = None
    delay_ms: Optional[float] = None
    jitter_ms: Optional[float] = None
    stratum: Optional[int] = None

    if code_sync == 0:
        for line in out_sync.splitlines():
            line_s = line.strip()
            if line_s.startswith("Server:"):
                server_str = line_s.split(":", 1)[1].strip()
            elif line_s.startswith("Offset:"):
                raw_offset = line_s.split(":", 1)[1].strip()
                offset_ms = parse_offset_ms(raw_offset)
            elif line_s.startswith("Delay:"):
                raw_delay = line_s.split(":", 1)[1].strip()
                delay_ms = parse_offset_ms(raw_delay)
            elif line_s.startswith("Jitter:"):
                raw_jitter = line_s.split(":", 1)[1].strip()
                jitter_ms = parse_offset_ms(raw_jitter)
            elif line_s.startswith("Stratum:"):
                try:
                    stratum = int(line_s.split(":", 1)[1].strip())
                except ValueError:
                    pass

    status = "HEALTHY"
    recommendations = []

    if not ntp_enabled:
        status = "CRITICAL"
        recommendations.append("NTP synchronization is disabled; run 'timedatectl set-ntp true'")
    elif not ntp_synced:
        status = "WARNING"
        recommendations.append("NTP is not yet synchronized with upstream timeserver")

    if offset_ms is not None and abs(offset_ms) > max_offset_ms:
        status = "CRITICAL"
        recommendations.append(f"Clock offset ({abs(offset_ms):.2f}ms) exceeds threshold ({max_offset_ms}ms)")

    if jitter_ms is not None and jitter_ms > max_jitter_ms:
        status = "WARNING"
        recommendations.append(f"NTP jitter ({jitter_ms:.2f}ms) exceeds threshold ({max_jitter_ms}ms)")

    recommendation = "; ".join(recommendations) if recommendations else "optimal"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "ntp_enabled": ntp_enabled,
            "ntp_synchronized": ntp_synced,
            "timezone": timezone_str,
            "server": server_str,
            "stratum": stratum,
            "offset_ms": offset_ms,
            "delay_ms": delay_ms,
            "jitter_ms": jitter_ms,
            "max_offset_threshold_ms": max_offset_ms,
            "max_jitter_threshold_ms": max_jitter_ms,
            "status": status,
            "recommendation": recommendation,
            "healthy": (status == "HEALTHY"),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Clock Drift Guard (Pattern 61)"
    )
    parser.add_argument(
        "--max-offset-ms",
        type=float,
        default=DEFAULT_MAX_OFFSET_MS,
        help=f"Max clock offset in ms before alert (default: {DEFAULT_MAX_OFFSET_MS})",
    )
    parser.add_argument(
        "--max-jitter-ms",
        type=float,
        default=DEFAULT_MAX_JITTER_MS,
        help=f"Max clock jitter in ms before warning (default: {DEFAULT_MAX_JITTER_MS})",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output raw JSON results",
    )

    args = parser.parse_args()

    results = audit_clock_sync(
        max_offset_ms=args.max_offset_ms,
        max_jitter_ms=args.max_jitter_ms,
    )

    if args.json:
        print(json.dumps(results, indent=2))
        return 0 if results["summary"]["healthy"] else 1

    summary = results["summary"]
    print(f"Jev Clock Drift Guard (Pattern 61) - {results['timestamp']}")
    print(f"Timezone:           {summary['timezone']}")
    print(f"NTP Synchronized:   {'YES' if summary['ntp_synchronized'] else 'NO'} ({summary['server']}, Stratum {summary['stratum']})")
    print(f"Clock Offset:       {summary['offset_ms']} ms")
    print(f"Roundtrip Delay:    {summary['delay_ms']} ms")
    print(f"Network Jitter:     {summary['jitter_ms']} ms")
    print(f"Health Status:      {summary['status']}")
    print(f"Recommendation:     {summary['recommendation']}")

    return 0 if summary["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
