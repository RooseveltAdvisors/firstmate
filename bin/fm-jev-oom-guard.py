#!/usr/bin/env python3
"""
fm-jev-oom-guard.py - Jev Multi-Agent Kernel OOM Score & Process Priority Bias Guard (Pattern 84)

Audits Linux kernel OOM scores (/proc/<pid>/oom_score), OOM adjustment biases (/proc/<pid>/oom_score_adj),
and process memory profiles across multi-agent supervisor hierarchies and transient worker processes.
Ensures critical long-running supervisor daemons (firstmate, wiseman, herdr, postgres, pi, agent-vault)
are protected from ungraceful kernel OOM termination, while transient test runners, headless browser
sandboxes, and compile workers absorb OOM kill priority under memory pressure.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful handling of missing or restricted /proc entries.
  - Fast bounded execution (< 0.05s) across full process table.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Set, Tuple

DEFAULT_WARN_OOM_SCORE = 900
DEFAULT_CRIT_OOM_SCORE = 950
DEFAULT_SUPERVISOR_WARN_SCORE = 850
DEFAULT_SUPERVISOR_MAX_ADJ = 0

DEFAULT_PROC_DIR = "/proc"

SUPERVISOR_NAMES = {
    "firstmate",
    "wiseman",
    "herdr",
    "postgres",
    "agent-vault",
}

TRANSIENT_KEYWORDS = {
    "chrome",
    "chromium",
    "playwright",
    "pytest",
    "vitest",
    "jest",
    "tsc",
    "esbuild",
    "rustc",
    "cargo",
    "webpack",
}


def is_supervisor_proc(comm: str, cmdline: str) -> bool:
    """Checks if a process belongs to the core supervisor daemon hierarchy."""
    c = comm.lower()
    cmd = cmdline.lower().strip()
    if c in SUPERVISOR_NAMES:
        return True
    if any(name in c for name in SUPERVISOR_NAMES):
        return True
    words = cmd.split()
    first_bin = words[0] if words else ""
    if c == "pi" or first_bin == "pi" or first_bin.endswith("/pi"):
        return True
    return False


def is_transient_proc(comm: str, cmdline: str) -> bool:
    """Checks if a process is a high-memory transient worker or sandbox."""
    c = comm.lower()
    cmd = cmdline.lower()
    return any(k in c or k in cmd for k in TRANSIENT_KEYWORDS)


def read_file_strip(path: str) -> Optional[str]:
    """Safely reads a single-line procfs file."""
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except Exception:
        return None


def parse_proc_status(status_path: str) -> Dict[str, str]:
    """Extracts key memory metrics from /proc/<pid>/status."""
    metrics: Dict[str, str] = {}
    if not os.path.exists(status_path):
        return metrics
    try:
        with open(status_path, "r") as f:
            for line in f:
                parts = line.strip().split(":", 1)
                if len(parts) == 2:
                    metrics[parts[0].strip()] = parts[1].strip()
    except Exception:
        pass
    return metrics


def audit_oom(
    proc_dir: str = DEFAULT_PROC_DIR,
    warn_score: int = DEFAULT_WARN_OOM_SCORE,
    crit_score: int = DEFAULT_CRIT_OOM_SCORE,
    sup_warn_score: int = DEFAULT_SUPERVISOR_WARN_SCORE,
    sup_max_adj: int = DEFAULT_SUPERVISOR_MAX_ADJ,
) -> Dict[str, Any]:
    """Audits process table OOM score distribution and supervisor isolation."""
    processes: List[Dict[str, Any]] = []
    supervisors_flagged: List[Dict[str, Any]] = []
    supervisors_found: List[Dict[str, Any]] = []
    transient_processes: List[Dict[str, Any]] = []
    issues: List[str] = []

    total_audited = 0
    max_system_score = 0
    max_supervisor_score = 0

    if not os.path.exists(proc_dir):
        return {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "summary": {
                "status": "HEALTHY",
                "healthy": True,
                "total_audited": 0,
                "max_system_score": 0,
                "max_supervisor_score": 0,
                "supervisors_flagged_count": 0,
                "issues": ["Procfs directory not accessible; fail-open."],
            },
            "top_oom_candidates": [],
            "supervisors": [],
        }

    try:
        entries = os.listdir(proc_dir)
    except Exception:
        entries = []

    for entry in entries:
        if not entry.isdigit():
            continue
        pid = int(entry)
        pid_dir = os.path.join(proc_dir, entry)

        score_str = read_file_strip(os.path.join(pid_dir, "oom_score"))
        if score_str is None:
            continue
        try:
            oom_score = int(score_str)
        except ValueError:
            continue

        adj_str = read_file_strip(os.path.join(pid_dir, "oom_score_adj"))
        oom_score_adj = int(adj_str) if (adj_str and adj_str.lstrip("-").isdigit()) else 0

        comm = read_file_strip(os.path.join(pid_dir, "comm")) or "unknown"
        cmdline_raw = read_file_strip(os.path.join(pid_dir, "cmdline")) or ""
        cmdline = cmdline_raw.replace("\x00", " ").strip()

        status_info = parse_proc_status(os.path.join(pid_dir, "status"))
        vm_rss = status_info.get("VmRSS", "0 kB")

        total_audited += 1
        if oom_score > max_system_score:
            max_system_score = oom_score

        is_supervisor = is_supervisor_proc(comm, cmdline)
        is_transient = is_transient_proc(comm, cmdline)

        proc_record = {
            "pid": pid,
            "comm": comm,
            "oom_score": oom_score,
            "oom_score_adj": oom_score_adj,
            "vm_rss": vm_rss,
            "is_supervisor": is_supervisor,
            "is_transient": is_transient,
        }
        processes.append(proc_record)

        if is_supervisor:
            supervisors_found.append(proc_record)
            if oom_score > max_supervisor_score:
                max_supervisor_score = oom_score
            if oom_score >= sup_warn_score or oom_score_adj > sup_max_adj:
                supervisors_flagged.append(proc_record)

        if is_transient:
            transient_processes.append(proc_record)

    processes.sort(key=lambda p: p["oom_score"], reverse=True)
    top_candidates = processes[:10]

    status = "HEALTHY"

    # Evaluate supervisor safety
    for sup in supervisors_flagged:
        if sup["oom_score"] >= crit_score:
            status = "CRITICAL"
            issues.append(
                f"Supervisor PID {sup['pid']} ({sup['comm']}) at severe OOM risk (score={sup['oom_score']})!"
            )
        elif sup["oom_score"] >= sup_warn_score:
            if status != "CRITICAL":
                status = "WARNING"
            issues.append(
                f"Supervisor PID {sup['pid']} ({sup['comm']}) has elevated OOM score ({sup['oom_score']})"
            )
        if sup["oom_score_adj"] > sup_max_adj:
            if status == "HEALTHY":
                status = "WARNING"
            issues.append(
                f"Supervisor PID {sup['pid']} ({sup['comm']}) has positive oom_score_adj ({sup['oom_score_adj']})"
            )

    # Evaluate system-wide extreme OOM pressure
    if max_system_score >= crit_score and status != "CRITICAL":
        status = "WARNING"
        issues.append(f"Near-imminent kernel OOM kill detected: peak system oom_score={max_system_score}")

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "total_audited": total_audited,
            "supervisors_count": len(supervisors_found),
            "supervisors_flagged_count": len(supervisors_flagged),
            "max_system_score": max_system_score,
            "max_supervisor_score": max_supervisor_score,
            "top_target_pid": top_candidates[0]["pid"] if top_candidates else None,
            "top_target_comm": top_candidates[0]["comm"] if top_candidates else None,
            "issues": issues,
        },
        "top_oom_candidates": top_candidates[:5],
        "flagged_supervisors": supervisors_flagged,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Kernel OOM Score & Process Priority Bias Guard (Pattern 84)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--warn-score", type=int, default=DEFAULT_WARN_OOM_SCORE, help=f"Warning system OOM score (default {DEFAULT_WARN_OOM_SCORE})")
    parser.add_argument("--crit-score", type=int, default=DEFAULT_CRIT_OOM_SCORE, help=f"Critical system OOM score (default {DEFAULT_CRIT_OOM_SCORE})")
    parser.add_argument("--sup-warn", type=int, default=DEFAULT_SUPERVISOR_WARN_SCORE, help=f"Supervisor warning score (default {DEFAULT_SUPERVISOR_WARN_SCORE})")
    parser.add_argument("--proc-dir", type=str, default=DEFAULT_PROC_DIR, help="Procfs directory path (default /proc)")

    args = parser.parse_args()

    result = audit_oom(
        proc_dir=args.proc_dir,
        warn_score=args.warn_score,
        crit_score=args.crit_score,
        sup_warn_score=args.sup_warn,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else ("\033[31m" if summary["status"] == "CRITICAL" else "\033[33m")
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Kernel OOM Score & Priority Guard (Pattern 84)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    print(f" Processes Audited:      {summary['total_audited']} ({summary['supervisors_count']} supervisor daemons)")
    print(f" Max System OOM Score:   {summary['max_system_score']} / 1000")
    print(f" Max Supervisor Score:   {summary['max_supervisor_score']} / 1000")
    if summary["top_target_comm"]:
        print(f" Top OOM Target:         PID {summary['top_target_pid']} ({summary['top_target_comm']})")

    if result["top_oom_candidates"]:
        print("\nTop OOM Kill Targets:")
        for p in result["top_oom_candidates"]:
            role = "Supervisor" if p["is_supervisor"] else ("Worker/Transient" if p["is_transient"] else "System/Other")
            print(f"  - PID {p['pid']:<7} [{role:<16}] {p['comm']:<20} score={p['oom_score']:<4} adj={p['oom_score_adj']:<4} RSS={p['vm_rss']}")

    if summary["issues"]:
        print("\nActive Issues & Priority Biases:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll multi-agent supervisors properly insulated from ungraceful OOM termination.")
    print("================================================================================")


if __name__ == "__main__":
    main()
