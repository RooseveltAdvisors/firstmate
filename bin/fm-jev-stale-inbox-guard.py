#!/usr/bin/env python3
"""
fm-jev-stale-inbox-guard.py - Jev Multi-Agent Fleet Worker Inbox Stale Backlog & Dead Endpoint Drain Guard

Audits /opt/ra/firstmate/state/*.inbox directories across the multi-agent fleet.
Identifies unhandled steer messages accumulating on dead, blocked, or finished
worker endpoints that trigger perpetual stack-monitor alerts and spurious supervisor wakes.
Safely drains/archives stagnant messages for dead endpoints to handled/.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path


def get_active_herdr_panes() -> dict[str, str]:
    """Retrieve active herdr panes and their status in a single call."""
    active = {}
    try:
        res = subprocess.run(
            ["herdr", "agent", "list"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if res.returncode == 0 and res.stdout.strip():
            data = json.loads(res.stdout)
            agents = data.get("result", {}).get("agents", [])
            for a in agents:
                pid = a.get("pane_id")
                if pid:
                    active[pid] = a.get("agent_status", "unknown")
    except Exception:
        pass
    return active


def is_task_endpoint_live(task_id: str, state_dir: Path, active_panes: dict[str, str]) -> tuple[bool, str]:
    """Check whether a task has an active, live endpoint or is dead/orphaned."""
    pres_file = state_dir / f"{task_id}.herdr-presentation"
    meta_file = state_dir / f"{task_id}.meta"
    status_file = state_dir / f"{task_id}.status"

    if not pres_file.is_file() and not meta_file.is_file() and not status_file.is_file():
        return False, "no_state_files_found"

    # Status ledger terminal check
    if status_file.is_file():
        try:
            lines = [l.strip() for l in status_file.read_text(encoding="utf-8", errors="replace").splitlines() if l.strip()]
            if lines:
                last_line = lines[-1]
                if last_line.startswith("done") or last_line.startswith("failed"):
                    return False, f"terminal_status: {last_line[:50]}"
        except Exception:
            pass

    # Presentation & Pane Liveness check
    if pres_file.is_file():
        try:
            content = pres_file.read_text(encoding="utf-8", errors="replace")
            pane_id = ""
            for line in content.splitlines():
                if line.startswith("pane_id="):
                    pane_id = line.split("=", 1)[1].strip()
                    break
            if pane_id:
                if pane_id not in active_panes:
                    return False, f"herdr_pane_{pane_id}_missing"
                status = active_panes.get(pane_id, "unknown")
                if status == "done":
                    return False, f"herdr_pane_{pane_id}_status_done"
                return True, f"herdr_pane_{pane_id}_{status}"
        except Exception:
            pass

    # Stale meta without presentation
    if meta_file.is_file() and not pres_file.is_file():
        try:
            mtime = meta_file.stat().st_mtime
            if time.time() - mtime > 43200:  # >12 hours
                return False, "meta_older_than_12h_no_presentation"
        except Exception:
            pass

    return True, "assumed_active"


def audit_inbox(inbox_dir: Path, now_epoch: int, max_age_secs: int) -> dict:
    """Audit unhandled messages inside an inbox directory."""
    task_id = inbox_dir.name[:-6] if inbox_dir.name.endswith(".inbox") else inbox_dir.name
    unhandled_files = []
    oldest_age = 0

    for msg_path in sorted(inbox_dir.glob("*.msg")):
        if msg_path.is_symlink() or not msg_path.is_file():
            continue
        try:
            mtime = int(msg_path.stat().st_mtime)
            age = max(0, now_epoch - mtime)
            unhandled_files.append({
                "path": str(msg_path),
                "name": msg_path.name,
                "mtime": mtime,
                "age_secs": age,
                "age_hours": round(age / 3600.0, 2),
            })
            if age > oldest_age:
                oldest_age = age
        except Exception:
            pass

    is_stale = oldest_age >= max_age_secs if unhandled_files else False

    return {
        "task_id": task_id,
        "inbox_path": str(inbox_dir),
        "unhandled_count": len(unhandled_files),
        "oldest_age_secs": oldest_age,
        "oldest_age_hours": round(oldest_age / 3600.0, 2),
        "is_stale": is_stale,
        "messages": unhandled_files,
    }


def drain_inbox_messages(inbox_info: dict, dry_run: bool = False) -> int:
    """Move unhandled messages to handled/ and clean ring-state."""
    if dry_run:
        return inbox_info["unhandled_count"]

    inbox_dir = Path(inbox_info["inbox_path"])
    handled_dir = inbox_dir / "handled"
    handled_dir.mkdir(parents=True, exist_ok=True)

    drained_count = 0
    for msg in inbox_info["messages"]:
        src = Path(msg["path"])
        dst = handled_dir / src.name
        if src.is_file() and not src.is_symlink():
            try:
                shutil.move(str(src), str(dst))
                drained_count += 1
            except Exception:
                pass

    ring_state = inbox_dir / ".ring-state"
    if ring_state.is_file():
        try:
            ring_state.unlink()
        except Exception:
            pass

    escalated = inbox_dir / ".escalated"
    if escalated.is_file():
        try:
            escalated.unlink()
        except Exception:
            pass

    return drained_count


def main():
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Fleet Worker Inbox Stale Backlog & Dead Endpoint Drain Guard"
    )
    parser.add_argument("--json", action="store_true", help="Output telemetry in JSON format")
    parser.add_argument("--dry-run", action="store_true", help="Evaluate eligibility without draining")
    parser.add_argument("--drain-dead", action="store_true", help="Automatically drain unhandled messages for dead endpoints")
    parser.add_argument("--max-age-hours", type=float, default=4.0, help="Threshold in hours to classify inbox as stale (default 4.0h)")
    parser.add_argument("--state-dir", type=str, default="", help="Override Firstmate state directory")
    args = parser.parse_args()

    script_path = Path(__file__).resolve()
    script_dir = script_path.parent
    fm_home = Path(os.environ.get("FM_HOME", script_dir.parent))
    state_dir = Path(args.state_dir) if args.state_dir else Path(os.environ.get("FM_STATE_OVERRIDE", fm_home / "state"))

    now_epoch = int(time.time())
    max_age_secs = int(args.max_age_hours * 3600)

    # Fetch active panes once
    active_panes = get_active_herdr_panes()

    inboxes_audited = []
    stale_inboxes = []
    total_unhandled = 0
    total_drained = 0

    if state_dir.is_dir():
        for inbox_path in sorted(state_dir.glob("*.inbox")):
            if not inbox_path.is_dir() or inbox_path.is_symlink():
                continue
            info = audit_inbox(inbox_path, now_epoch, max_age_secs)
            if info["unhandled_count"] > 0:
                total_unhandled += info["unhandled_count"]
                is_live, liveness_reason = is_task_endpoint_live(info["task_id"], state_dir, active_panes)
                info["is_live"] = is_live
                info["liveness_reason"] = liveness_reason

                if info["is_stale"]:
                    stale_inboxes.append(info)

                if not is_live and args.drain_dead:
                    drained = drain_inbox_messages(info, dry_run=args.dry_run)
                    info["drained_count"] = drained
                    total_drained += drained

            inboxes_audited.append(info)

    total_inboxes = len(inboxes_audited)
    stale_count = len(stale_inboxes)

    status = "HEALTHY"
    if stale_count > 5 and not args.drain_dead:
        status = "WARNING"

    summary_text = (
        f"{total_inboxes} inboxes audited; "
        f"{total_unhandled} unhandled messages; "
        f"{stale_count} stale inboxes (>{args.max_age_hours}h); "
        f"{total_drained} drained ({status})"
    )

    result = {
        "status": status,
        "summary": summary_text,
        "telemetry": {
            "total_inboxes": total_inboxes,
            "total_unhandled_messages": total_unhandled,
            "stale_inboxes_count": stale_count,
            "drained_messages_count": total_drained,
            "max_age_hours": args.max_age_hours,
            "state_dir": str(state_dir),
            "stale_tasks": [i["task_id"] for i in stale_inboxes],
        },
        "stale_inboxes_detail": [
            {
                "task_id": i["task_id"],
                "unhandled_count": i["unhandled_count"],
                "oldest_age_hours": i["oldest_age_hours"],
                "is_live": i.get("is_live", True),
                "liveness_reason": i.get("liveness_reason", ""),
                "drained": i.get("drained_count", 0),
            }
            for i in stale_inboxes
        ],
    }

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[fm-jev-stale-inbox-guard] {summary_text}")
        for s in stale_inboxes[:10]:
            live_tag = "LIVE" if s.get("is_live", True) else "DEAD"
            print(f"  * {s['task_id']} [{live_tag}]: {s['unhandled_count']} msgs, oldest {s['oldest_age_hours']}h ({s.get('liveness_reason', '')})")

    sys.exit(0 if status == "HEALTHY" else 1)


if __name__ == "__main__":
    main()
