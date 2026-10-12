#!/usr/bin/env python3
"""
fm-jev-inactive-outcome-reconciler.py - Jev Terminal Inactive-Outcome Auto-Reconciliation & Wake Guard

Audits /opt/ra/firstmate/state/terminal-outcomes/*.pending records produced by
fm-inactive-reconcile.sh scan. Detects outcomes for children that are already
concluded, merged, or recorded as done in their status ledgers, and auto-acknowledges
them via bin/fm-inactive-reconcile.sh acknowledge <fingerprint>.

This eliminates spurious FIRSTMATE WATCHER WAKE: check: inactive-outcome wakeups
that interrupt Firstmate and waste context window and model tokens on already-finished work.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path


def parse_record(filepath: Path) -> dict:
    """Parse key=value metadata from a terminal outcome record."""
    data = {}
    try:
        content = filepath.read_text(encoding="utf-8", errors="replace")
        for line in content.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                k, v = line.split("=", 1)
                data[k.strip()] = v.strip()
    except Exception as exc:
        data["_read_error"] = str(exc)
    return data


def is_task_terminal_done(task_id: str, state_dir: Path) -> tuple[bool, str]:
    """Check if task_id has reached a terminal done state in its status ledger or presentation."""
    if not task_id:
        return False, "no_task_id"

    # Check status file
    status_file = state_dir / f"{task_id}.status"
    if status_file.is_file():
        try:
            lines = [l.strip() for l in status_file.read_text(encoding="utf-8", errors="replace").splitlines() if l.strip()]
            if lines:
                last_line = lines[-1]
                if last_line.startswith("done") or "state: done" in last_line or "state=done" in last_line:
                    return True, f"status_ledger_ends_done: {last_line[:80]}"
                if last_line.startswith("resolved"):
                    return True, f"status_ledger_ends_resolved: {last_line[:80]}"
        except Exception:
            pass

    # Check herdr-presentation file
    presentation_file = state_dir / f"{task_id}.herdr-presentation"
    if presentation_file.is_file():
        return True, "herdr_presentation_file_exists"

    return False, "not_terminal_in_ledger"


def reconcile_outcome(fingerprint: str, script_dir: Path, state_dir: Path, dry_run: bool = False) -> tuple[bool, str]:
    """Invoke fm-inactive-reconcile.sh acknowledge <fingerprint> or perform atomic rename."""
    if dry_run:
        return True, "dry_run_eligible"

    # First attempt: use fm-inactive-reconcile.sh if available
    reconcile_bin = script_dir / "fm-inactive-reconcile.sh"
    if reconcile_bin.is_file() and os.access(reconcile_bin, os.X_OK):
        env = os.environ.copy()
        env["FM_STATE_OVERRIDE"] = str(state_dir)
        try:
            res = subprocess.run(
                [str(reconcile_bin), "acknowledge", fingerprint],
                env=env,
                capture_output=True,
                text=True,
                timeout=10,
            )
            if res.returncode == 0:
                return True, "acknowledged_via_fm_inactive_reconcile"
        except Exception:
            pass

    # Fallback atomic rename: move .pending to .presented
    outcomes_dir = state_dir / "terminal-outcomes"
    pending = outcomes_dir / f"{fingerprint}.pending"
    presented = outcomes_dir / f"{fingerprint}.presented"
    if pending.is_file() and not pending.is_symlink():
        try:
            pending.rename(presented)
            return True, "acknowledged_via_atomic_rename"
        except Exception as exc:
            return False, f"rename_failed: {exc}"

    return False, "pending_file_not_found"


def main():
    parser = argparse.ArgumentParser(
        description="Jev Terminal Inactive-Outcome Auto-Reconciler & Wake Guard for Firstmate"
    )
    parser.add_argument("--json", action="store_true", help="Output telemetry in JSON format")
    parser.add_argument("--dry-run", action="store_true", help="Evaluate eligibility without acknowledging")
    parser.add_argument("--all-done", action="store_true", help="Auto-acknowledge all pending records with state=done")
    parser.add_argument("--max-age-secs", type=int, default=0, help="Auto-acknowledge records older than N seconds")
    parser.add_argument("--state-dir", type=str, default="", help="Override Firstmate state directory")
    args = parser.parse_args()

    script_path = Path(__file__).resolve()
    script_dir = script_path.parent
    fm_home = Path(os.environ.get("FM_HOME", script_dir.parent))
    state_dir = Path(args.state_dir) if args.state_dir else Path(os.environ.get("FM_STATE_OVERRIDE", fm_home / "state"))
    outcomes_dir = state_dir / "terminal-outcomes"

    now_epoch = int(time.time())
    pending_records = []
    reconciled_fingerprints = []
    retained_records = []

    if outcomes_dir.is_dir():
        for pending_path in sorted(outcomes_dir.glob("*.pending")):
            if pending_path.is_symlink():
                continue
            rec = parse_record(pending_path)
            fingerprint = rec.get("fingerprint", pending_path.stem)
            rec["_path"] = str(pending_path)
            rec["_fingerprint"] = fingerprint
            pending_records.append(rec)

            task_id = rec.get("task_id", "")
            state = rec.get("state", "")
            created_epoch = int(rec.get("created_epoch", 0) or 0)
            age_secs = max(0, now_epoch - created_epoch) if created_epoch else 0
            rec["_age_secs"] = age_secs

            eligible = False
            reason = ""

            # Check 1: Explicit --all-done and state is done
            if args.all_done and state == "done":
                eligible = True
                reason = "all_done_flag_and_state_done"

            # Check 2: Max age exceeded
            elif args.max_age_secs > 0 and age_secs >= args.max_age_secs:
                eligible = True
                reason = f"age_{age_secs}s_exceeds_max_{args.max_age_secs}s"

            # Check 3: Task status ledger is already terminal done
            else:
                is_done, ledger_reason = is_task_terminal_done(task_id, state_dir)
                if is_done and state == "done":
                    eligible = True
                    reason = ledger_reason

            rec["_eligible"] = eligible
            rec["_reason"] = reason

            if eligible:
                success, ack_msg = reconcile_outcome(fingerprint, script_dir, state_dir, dry_run=args.dry_run)
                rec["_reconciled"] = success
                rec["_ack_msg"] = ack_msg
                if success:
                    reconciled_fingerprints.append({
                        "fingerprint": fingerprint,
                        "task_id": task_id,
                        "state": state,
                        "reason": reason,
                        "action": "dry_run" if args.dry_run else "reconciled",
                        "detail": ack_msg
                    })
                else:
                    retained_records.append(rec)
            else:
                retained_records.append(rec)

    pending_count = len(pending_records)
    reconciled_count = len(reconciled_fingerprints)
    retained_count = len(retained_records)

    status = "HEALTHY"
    if retained_count > 10:
        status = "WARNING"

    summary_text = (
        f"{pending_count} pending terminal outcomes; "
        f"{reconciled_count} reconciled; "
        f"{retained_count} retained ({status})"
    )

    result = {
        "status": status,
        "summary": summary_text,
        "telemetry": {
            "pending_count": pending_count,
            "reconciled_count": reconciled_count,
            "retained_count": retained_count,
            "state_dir": str(state_dir),
            "outcomes_dir": str(outcomes_dir),
            "reconciled_fingerprints": reconciled_fingerprints,
            "retained_fingerprints": [r.get("_fingerprint") for r in retained_records],
        }
    }

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[fm-jev-inactive-outcome-reconciler] {summary_text}")
        for r in reconciled_fingerprints:
            print(f"  * Reconciled {r['fingerprint'][:12]} ({r['task_id']}): {r['reason']} [{r['action']}]")
        for ret in retained_records:
            print(f"  - Retained {ret.get('_fingerprint', '')[:12]} ({ret.get('task_id', '')}): state={ret.get('state', '')}")

    sys.exit(0 if status == "HEALTHY" else 1)


if __name__ == "__main__":
    main()
