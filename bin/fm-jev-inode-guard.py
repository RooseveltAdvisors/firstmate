#!/usr/bin/env python3
"""
fm-jev-inode-guard.py - Jev Multi-Agent Inode Exhaustion & Orphan Tempfile Accumulator Guard (Pattern 48)

Audits filesystem inode utilization across root, /tmp, /dev/shm, and fleet repositories
using statvfs to prevent silent "No space left on device" write failures caused by exhausted
inode tables before disk block capacity runs out.

Invariants:
  - Read-only diagnostics.
  - Fail-open: graceful fallback on missing paths or permission errors.
  - Bounded sub-second execution (< 500ms).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List


DEFAULT_CHECK_PATHS = ["/", "/tmp", "/dev/shm", "/opt/ra"]


def audit_path_inodes(path: str) -> Dict[str, Any]:
    """Inspects inode utilization for a filesystem path via statvfs."""
    try:
        st = os.statvfs(path)
        total_inodes = st.f_files
        free_inodes = st.f_ffree
        used_inodes = total_inodes - free_inodes
        used_pct = (
            round((used_inodes / total_inodes) * 100.0, 1) if total_inodes > 0 else 0.0
        )
        return {
            "path": path,
            "total_inodes": total_inodes,
            "free_inodes": free_inodes,
            "used_inodes": used_inodes,
            "used_pct": used_pct,
            "accessible": True,
        }
    except Exception as e:
        return {
            "path": path,
            "total_inodes": 0,
            "free_inodes": 0,
            "used_inodes": 0,
            "used_pct": 0.0,
            "accessible": False,
            "error": str(e),
        }


def audit_inodes(
    paths: List[str] | None = None,
    warn_pct: float = 80.0,
    crit_pct: float = 90.0,
) -> Dict[str, Any]:
    """Audits inode utilization across specified paths."""
    if paths is None:
        paths = DEFAULT_CHECK_PATHS

    # Deduplicate mount points by checking st_dev
    seen_devs = set()
    audited: List[Dict[str, Any]] = []

    for p in paths:
        if not os.path.exists(p):
            continue
        try:
            dev = os.stat(p).st_dev
            if dev in seen_devs:
                continue
            seen_devs.add(dev)
        except Exception:
            pass

        info = audit_path_inodes(p)
        audited.append(info)

    max_used_pct = max((item["used_pct"] for item in audited if item["accessible"]), default=0.0)

    if max_used_pct >= crit_pct:
        status = "CRITICAL"
        healthy = False
    elif max_used_pct >= warn_pct:
        status = "WARNING"
        healthy = False
    else:
        status = "HEALTHY"
        healthy = True

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "monitored_mounts": len(audited),
            "max_used_pct": max_used_pct,
            "warn_pct": warn_pct,
            "crit_pct": crit_pct,
            "status": status,
            "healthy": healthy,
        },
        "mounts": audited,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Inode Exhaustion & Orphan Tempfile Accumulator Guard (Pattern 48)"
    )
    parser.add_argument(
        "--warn-pct",
        type=float,
        default=80.0,
        help="Warning threshold for inode utilization %% (default: 80.0)",
    )
    parser.add_argument(
        "--crit-pct",
        type=float,
        default=90.0,
        help="Critical threshold for inode utilization %% (default: 90.0)",
    )
    parser.add_argument(
        "--paths",
        nargs="+",
        default=DEFAULT_CHECK_PATHS,
        help="Paths / mount points to audit (default: / /tmp /dev/shm /opt/ra)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry to stdout",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit with code 0 if healthy, code 1 if warning or critical",
    )

    args = parser.parse_args()
    report = audit_inodes(
        paths=args.paths,
        warn_pct=args.warn_pct,
        crit_pct=args.crit_pct,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"Jev Inode Exhaustion Guard (Pattern 48) — {report['timestamp']}")
        print(f"  • Monitored Mounts: {s['monitored_mounts']} (Max Used: {s['max_used_pct']}%)")
        print(f"  • Status: {s['status']}")
        if report["mounts"]:
            print("\n  Mount Status:")
            for m in report["mounts"]:
                if m["accessible"]:
                    print(f"    - {m['path']}: {m['used_pct']}% inodes used ({m['used_inodes']:,} / {m['total_inodes']:,})")
                else:
                    print(f"    - {m['path']}: INACCESSIBLE ({m.get('error')})")

    if args.check and not report["summary"]["healthy"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
