#!/usr/bin/env python3
"""
bin/fm-jev-binfmt-misc-guard.py - Linux Binary Format Emulation (binfmt_misc) Guard (Pattern 307 / Pattern 445)

Audits Linux kernel miscellaneous binary format handling (/proc/sys/fs/binfmt_misc/):
  - /proc/sys/fs/binfmt_misc/status: Global binfmt_misc subsystem registration and status (enabled)
  - /proc/sys/fs/binfmt_misc/*: Registered format handlers, interpreter paths, flags, and magic signatures
  - Disk verification: Checks that all registered binary interpreters exist on the host filesystem

Invariants:
  - binfmt_misc status must be 'enabled' when handlers are configured.
  - All registered format handlers with 'enabled' status must point to valid interpreters on disk.
  - Fail-open: graceful fallback when binfmt_misc is not mounted or restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

PROC_BINFMT_MISC_DIR = "/proc/sys/fs/binfmt_misc"
PROC_BINFMT_STATUS = "/proc/sys/fs/binfmt_misc/status"
IGNORE_ENTRIES = {"status", "register"}


def parse_binfmt_entry(entry_path: Path) -> Optional[Dict[str, Any]]:
    if not entry_path.is_file() or entry_path.name in IGNORE_ENTRIES:
        return None

    try:
        lines = entry_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None

    if not lines:
        return None

    first_line = lines[0].strip().lower()
    if first_line not in ("enabled", "disabled"):
        return None

    enabled = first_line == "enabled"
    interpreter: Optional[str] = None
    flags: str = ""
    offset: int = 0
    magic: Optional[str] = None
    mask: Optional[str] = None

    for line in lines[1:]:
        line_str = line.strip()
        if line_str.startswith("interpreter "):
            interpreter = line_str[len("interpreter ") :].strip()
        elif line_str.startswith("flags:"):
            flags = line_str[len("flags:") :].strip()
        elif line_str.startswith("offset "):
            try:
                offset = int(line_str[len("offset ") :].strip())
            except ValueError:
                pass
        elif line_str.startswith("magic "):
            magic = line_str[len("magic ") :].strip()
        elif line_str.startswith("mask "):
            mask = line_str[len("mask ") :].strip()

    interpreter_exists = False
    if interpreter:
        interpreter_path = Path(interpreter)
        try:
            interpreter_exists = interpreter_path.is_file()
        except OSError:
            interpreter_exists = False

    return {
        "name": entry_path.name,
        "enabled": enabled,
        "interpreter": interpreter,
        "interpreter_exists": interpreter_exists,
        "flags": flags,
        "offset": offset,
        "magic": magic,
        "mask": mask,
    }


def evaluate_binfmt_misc(
    binfmt_dir: str = PROC_BINFMT_MISC_DIR,
    status_file: str = PROC_BINFMT_STATUS,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    binfmt_path = Path(binfmt_dir)
    status_path = Path(status_file)

    global_status = "unavailable"
    if status_path.is_file():
        try:
            content = status_path.read_text(encoding="utf-8", errors="replace").strip().lower()
            if content in ("enabled", "disabled"):
                global_status = content
            else:
                global_status = content or "unknown"
        except OSError:
            global_status = "unreadable"

    handlers: Dict[str, Any] = {}
    enabled_count = 0
    disabled_count = 0
    missing_interpreters: List[str] = []

    if binfmt_path.is_dir():
        try:
            for entry in binfmt_path.iterdir():
                parsed = parse_binfmt_entry(entry)
                if parsed:
                    name = parsed["name"]
                    handlers[name] = parsed
                    if parsed["enabled"]:
                        enabled_count += 1
                        if parsed["interpreter"] and not parsed["interpreter_exists"]:
                            missing_interpreters.append(name)
                    else:
                        disabled_count += 1
        except OSError:
            pass

    if global_status == "disabled":
        issues.append("Kernel binfmt_misc binary format subsystem is globally disabled")
        recommendations.append("Enable binfmt_misc: echo 1 > /proc/sys/fs/binfmt_misc/status")
        status = "WARNING"

    if missing_interpreters:
        issues.append(
            f"Registered binfmt handlers reference missing interpreters on disk: {missing_interpreters}"
        )
        recommendations.append("Install required binary emulators (e.g. qemu-user-static) or re-register valid interpreters")
        status = "WARNING"

    healthy = len(issues) == 0

    return {
        "pattern": 307,
        "name": "binfmt_misc",
        "description": "Linux Kernel Miscellaneous Binary Format Emulation & Handler Guard",
        "status": status,
        "healthy": healthy,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "binfmt_status": global_status,
        "total_registered": len(handlers),
        "enabled_count": enabled_count,
        "disabled_count": disabled_count,
        "handlers": handlers,
        "missing_interpreters": missing_interpreters,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Linux Kernel Miscellaneous Binary Format Emulation & Handler Guard (Pattern 307 / Pattern 445)"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--binfmt-dir", default=PROC_BINFMT_MISC_DIR, help="Path to /proc/sys/fs/binfmt_misc")
    parser.add_argument("--status-file", default=PROC_BINFMT_STATUS, help="Path to /proc/sys/fs/binfmt_misc/status")
    args = parser.parse_args()

    result = evaluate_binfmt_misc(
        binfmt_dir=args.binfmt_dir,
        status_file=args.status_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] Pattern {result['pattern']} - {result['description']}")
        print(f"  Subsystem Status: {result['binfmt_status']}")
        print(f"  Total Handlers: {result['total_registered']} (Enabled: {result['enabled_count']}, Disabled: {result['disabled_count']})")
        if result["handlers"]:
            print("  Registered Handlers:")
            for name, h in result["handlers"].items():
                interp = h.get("interpreter", "none")
                exists = "valid" if h.get("interpreter_exists") else "missing"
                print(f"    - {name}: enabled={h['enabled']}, interpreter={interp} ({exists})")
        if result["issues"]:
            print("  Issues:")
            for issue in result["issues"]:
                print(f"    - {issue}")
        if result["recommendations"]:
            print("  Recommendations:")
            for rec in result["recommendations"]:
                print(f"    - {rec}")

    if not result["healthy"]:
        sys.exit(1 if result["status"] == "WARNING" else 2)


if __name__ == "__main__":
    main()
