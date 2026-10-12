#!/usr/bin/env python3
"""
fm-jev-zombie-guard.py - Jev Multi-Agent Subprocess Zombie & Defunct PPID Leak Guard (Pattern 45)

Audits host process tree for zombie/defunct (state 'Z') processes and traces them to
their parent PID (PPID). Identifies broken multi-agent harnesses, unhandled SIGCHLD signals,
and missing wait()/waitpid() calls before process table slots are exhausted.

Invariants:
  - Read-only diagnostics. Non-destructive: never signals PIDs unexpectedly.
  - Sub-second bounded execution (< 500ms).
  - Fail-open: graceful fallback on missing /proc permissions.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional


def get_process_cmdline(pid: int) -> str:
    """Reads cmdline of a given PID from /proc."""
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            raw = f.read()
            return raw.replace(b"\x00", b" ").decode("utf-8", errors="replace").strip()
    except Exception:
        return ""


def get_process_name(pid: int) -> str:
    """Reads comm name of a given PID from /proc."""
    try:
        with open(f"/proc/{pid}/comm", "r", errors="replace") as f:
            return f.read().strip()
    except Exception:
        return f"unknown[{pid}]"


def audit_zombies(
    warn_threshold: int = 5,
    crit_threshold: int = 20,
) -> Dict[str, Any]:
    """Audits /proc for processes in zombie state ('Z')."""
    zombies: List[Dict[str, Any]] = []
    parents: Dict[int, Dict[str, Any]] = {}

    try:
        proc_entries = os.listdir("/proc")
    except Exception as e:
        return {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "summary": {
                "total_zombies": 0,
                "parents_count": 0,
                "status": "ERROR",
                "healthy": False,
                "error": str(e),
            },
            "zombies": [],
            "parents": {},
        }

    for entry in proc_entries:
        if not entry.isdigit():
            continue
        pid = int(entry)
        stat_path = f"/proc/{pid}/stat"
        try:
            with open(stat_path, "r", errors="replace") as f:
                content = f.read()
                # /proc/[pid]/stat format: pid (comm) state ppid ...
                # comm can contain spaces and parentheses, find last ')'
                rparen = content.rfind(")")
                if rparen == -1:
                    continue
                comm = content[content.find("(") + 1 : rparen]
                rest = content[rparen + 2 :].split()
                if not rest:
                    continue
                state = rest[0]
                ppid = int(rest[1]) if len(rest) > 1 and rest[1].isdigit() else 0

                if state == "Z":
                    parent_comm = get_process_name(ppid)
                    parent_cmd = get_process_cmdline(ppid)
                    z_entry = {
                        "pid": pid,
                        "ppid": ppid,
                        "comm": comm,
                        "parent_comm": parent_comm,
                        "parent_cmdline": parent_cmd[:120] if parent_cmd else parent_comm,
                    }
                    zombies.append(z_entry)

                    if ppid not in parents:
                        parents[ppid] = {
                            "ppid": ppid,
                            "parent_comm": parent_comm,
                            "parent_cmdline": parent_cmd[:120] if parent_cmd else parent_comm,
                            "zombie_count": 0,
                            "zombie_pids": [],
                        }
                    parents[ppid]["zombie_count"] += 1
                    parents[ppid]["zombie_pids"].append(pid)
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
        except Exception:
            continue

    total_zombies = len(zombies)
    if total_zombies >= crit_threshold:
        status = "CRITICAL"
        healthy = False
    elif total_zombies >= warn_threshold:
        status = "WARNING"
        healthy = False
    else:
        status = "HEALTHY"
        healthy = True

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "total_zombies": total_zombies,
            "parents_count": len(parents),
            "warn_threshold": warn_threshold,
            "crit_threshold": crit_threshold,
            "status": status,
            "healthy": healthy,
        },
        "zombies": zombies,
        "parents": list(parents.values()),
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Subprocess Zombie & Defunct PPID Leak Guard (Pattern 45)"
    )
    parser.add_argument(
        "--warn-threshold",
        type=int,
        default=5,
        help="Warning threshold for zombie process count (default: 5)",
    )
    parser.add_argument(
        "--crit-threshold",
        type=int,
        default=20,
        help="Critical threshold for zombie process count (default: 20)",
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
    report = audit_zombies(
        warn_threshold=args.warn_threshold,
        crit_threshold=args.crit_threshold,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"Jev Zombie & Defunct PPID Leak Guard (Pattern 45) — {report['timestamp']}")
        print(f"  • Total Zombies: {s['total_zombies']} (Warn: {s['warn_threshold']}, Crit: {s['crit_threshold']})")
        print(f"  • Responsible Parents (PPIDs): {s['parents_count']}")
        print(f"  • Status: {s['status']}")
        if report["parents"]:
            print("\n  Leaking Parent Processes:")
            for p in report["parents"]:
                print(f"    - PPID {p['ppid']} ({p['parent_comm']}): {p['zombie_count']} zombies [PIDs: {', '.join(map(str, p['zombie_pids'][:5]))}{'...' if len(p['zombie_pids']) > 5 else ''}]")
                if p["parent_cmdline"]:
                    print(f"      Cmd: {p['parent_cmdline']}")

    if args.check and not report["summary"]["healthy"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
