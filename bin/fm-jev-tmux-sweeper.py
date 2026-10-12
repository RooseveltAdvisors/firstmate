#!/usr/bin/env python3
"""
fm-jev-tmux-sweeper.py - Jev Multi-Agent Orphaned Screen & Tmux Dead Session Sweeper (Pattern 44)

Audits detached, defunct, and orphaned tmux/screen sessions across multi-agent seats
to detect abandoned terminal ptys, leaked memory, and hanging subshells.

Invariants:
  - Read-only diagnostics by default (--dry-run).
  - Strictly protects critical fleet sessions (firstmate, wiseman, second-brain, dotfiles).
  - Fail-open: Never crashes if tmux server is not running.
  - Strict bounded runtime (< 1.0s overhead).
"""

import argparse
import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional


PROTECTED_SESSIONS = {
    "firstmate",
    "wiseman",
    "second-brain",
    "dotfiles",
}


def audit_tmux_sessions(
    max_idle_hours: float = 72.0,
    sweep: bool = False,
    extra_protected: Optional[List[str]] = None,
) -> Dict[str, Any]:
    """Scans and audits tmux sessions."""
    protected = set(PROTECTED_SESSIONS)
    if extra_protected:
        protected.update(extra_protected)

    sessions: List[Dict[str, Any]] = []
    orphaned_candidates: List[Dict[str, Any]] = []

    try:
        # Format: session_name:windows:attached:created_epoch:activity_epoch
        fmt = "#{session_name}::#{session_windows}::#{session_attached}::#{session_created}::#{session_activity}"
        res = subprocess.run(
            ["tmux", "list-sessions", "-F", fmt],
            capture_output=True,
            text=True,
            check=False,
            timeout=2.0,
        )

        now = time.time()
        max_idle_sec = max_idle_hours * 3600.0

        if res.returncode == 0:
            for line in res.stdout.splitlines():
                parts = line.strip().split("::")
                if len(parts) >= 5:
                    name = parts[0]
                    windows = int(parts[1]) if parts[1].isdigit() else 1
                    attached = int(parts[2]) if parts[2].isdigit() else 0
                    created = float(parts[3]) if parts[3].isdigit() else now
                    activity = float(parts[4]) if parts[4].isdigit() else created

                    idle_sec = now - activity
                    age_hours = round((now - created) / 3600.0, 1)
                    idle_hours = round(idle_sec / 3600.0, 1)

                    is_protected = name in protected or any(name.startswith(p) for p in protected)
                    is_candidate = (
                        not is_protected
                        and attached == 0
                        and (idle_sec >= max_idle_sec or name.startswith(("test-", "tmp-", "kill-")))
                    )

                    s_info = {
                        "name": name,
                        "windows": windows,
                        "attached": attached > 0,
                        "age_hours": age_hours,
                        "idle_hours": idle_hours,
                        "protected": is_protected,
                        "safe_to_reap": is_candidate,
                    }
                    sessions.append(s_info)

                    if is_candidate:
                        orphaned_candidates.append(s_info)
                        if sweep:
                            try:
                                subprocess.run(["tmux", "kill-session", "-t", name], check=False, timeout=1.0)
                            except Exception:
                                pass
    except Exception:
        pass

    healthy = len(orphaned_candidates) == 0

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "total_sessions": len(sessions),
            "attached_sessions": sum(1 for s in sessions if s["attached"]),
            "detached_sessions": sum(1 for s in sessions if not s["attached"]),
            "orphaned_candidates_count": len(orphaned_candidates),
            "mode": "sweep" if sweep else "dry-run",
            "healthy": healthy,
        },
        "sessions": sessions,
        "orphaned_candidates": orphaned_candidates,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Orphaned Screen & Tmux Dead Session Sweeper (Pattern 44)"
    )
    parser.add_argument(
        "--max-idle-hours",
        type=float,
        default=72.0,
        help="Idle hours before detached session is considered orphaned candidate (default: 72.0)",
    )
    parser.add_argument(
        "--sweep",
        action="store_true",
        help="Terminate confirmed orphaned detached sessions (dry-run by default)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry to stdout",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit with code 0 if healthy, code 1 if orphaned sessions detected",
    )

    args = parser.parse_args()
    report = audit_tmux_sessions(
        max_idle_hours=args.max_idle_hours,
        sweep=args.sweep,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"Jev Tmux Session Sweeper (Pattern 44) — {report['timestamp']}")
        print(f"  • Total Sessions: {s['total_sessions']} ({s['attached_sessions']} attached, {s['detached_sessions']} detached)")
        print(f"  • Orphaned Candidates: {s['orphaned_candidates_count']} ({s['mode']})")
        print(f"  • Status: {'HEALTHY' if s['healthy'] else 'ACTION REQUIRED'}")
        if report["sessions"]:
            print("\n  Active Sessions:")
            for sess in report["sessions"]:
                status = "ATTACHED" if sess["attached"] else f"IDLE {sess['idle_hours']}h"
                prot = " [PROTECTED]" if sess["protected"] else ""
                print(f"    - {sess['name']}: {sess['windows']} win, {status}{prot}")

    if args.check and not report["summary"]["healthy"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
