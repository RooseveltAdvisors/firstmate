#!/usr/bin/env python3
"""fm-jev-alert-correlator.py - Semantic Alert Deduping & Pager Fatigue Dampening via Jev.

Correlates incoming stack-monitor checks, pager rails, and wake signals against
active holds, open beads, and maintenance windows, suppressing duplicate alerts.

Usage:
  fm-jev-alert-correlator.py --alert "<text>" [--source <name>] [--json]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

TS_BASE = "https://api.typesafe.ai"
TS_MODEL = "jev-latest"
TS_TIMEOUT = 4.0
DEFAULT_CACHE = "/dev/shm/.fm-jev-alert-cache.json"


def get_cache_path() -> Path:
    return Path(os.environ.get("FM_ALERT_CACHE_OVERRIDE", DEFAULT_CACHE))


def get_api_key() -> str | None:
    # 1. Resolve directly from Agent Vault via Jev service (Strict Invariant)
    try:
        sys.path.insert(0, "/opt/ra/firstmate/projects/jev/src")
        from jev.vault import get_typesafe_api_key
        return get_typesafe_api_key()
    except Exception:
        pass

    # 2. Try Jev service CLI runner if available
    jev_bin = Path("/opt/ra/firstmate/projects/jev/bin/jev")
    if jev_bin.exists():
        try:
            res = subprocess.run(
                [str(jev_bin), "run", "--", "env"],
                capture_output=True,
                text=True,
                timeout=3,
                check=False,
            )
            for line in res.stdout.splitlines():
                if line.startswith("TYPESAFE_API_KEY="):
                    k = line.split("=", 1)[1].strip()
                    if k:
                        return k
        except Exception:
            pass

    return None


def log_telemetry(
    action: str, tier: str, code: str, source: str, alert_text: str, detail: str = ""
) -> None:
    fm_root = Path(os.environ.get("FM_HOME", "/opt/ra/firstmate"))
    state_dir = Path(os.environ.get("FM_STATE_OVERRIDE", fm_root / "state"))
    telem_file = state_dir / ".jev-alert-telemetry"
    try:
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        clean_alert = " ".join(alert_text.split())[:120]
        clean_detail = " ".join(detail.split())[:160]
        line = f"{ts}\t{action}\t{tier}\t{code}\t{source}\t{clean_alert}\t{clean_detail}\n"
        with open(telem_file, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass


def emit_result(
    action: str,
    code: str,
    reason: str,
    tier: str = "tier1",
    source: str = "",
    alert_text: str = "",
    as_json: bool = False,
    exit_code: int = 0,
    detail: str = "",
) -> None:
    log_telemetry(action, tier, code, source, alert_text, detail)
    if as_json:
        payload = {
            "action": action,
            "code": code,
            "reason": reason,
            "tier": tier,
            "source": source,
            "detail": detail,
        }
        print(json.dumps(payload, indent=2))
        sys.exit(exit_code)

    if action == "absorb":
        print(f"DECISION: absorb [{code}] {reason}")
    else:
        print(f"DECISION: escalate [{code}] {reason}")
    sys.exit(exit_code)


def load_active_holds(state_dir: Path) -> list[str]:
    holds = []
    if not state_dir.exists():
        return holds
    for hf in state_dir.glob("captain-hold-*.status"):
        try:
            content = hf.read_text(encoding="utf-8", errors="replace")
            holds.append(f"{hf.name}: {content[:200]}")
        except Exception:
            pass
    for hf in state_dir.glob("*.hold"):
        try:
            content = hf.read_text(encoding="utf-8", errors="replace")
            holds.append(f"{hf.name}: {content[:200]}")
        except Exception:
            pass
    return holds


def normalize_fingerprint(alert_text: str) -> str:
    """Normalize an alert into a repeat fingerprint.

    Counters, timestamps, hashes, and paths change on every poll of the same
    condition (open=1 -> open=7), which defeated the old exact-text hash and let
    ~88% of escalations through as apparent 'new incidents'.
    ponytail: digit normalization merges count-only changes; a real status-word
    change (unreachable vs down) still yields a different fingerprint.
    """
    s = alert_text.lower()
    s = re.sub(r"\b[0-9a-f]{12,}\b", "H", s)
    s = re.sub(r"\d+", "N", s)
    s = re.sub(r"[^\w\s]", " ", s)
    return " ".join(s.split())


def check_fingerprint_dampen(alert_text: str) -> tuple[bool, int]:
    """Tier 1b: dampen repeats of an already-seen alert fingerprint.

    Returns (should_absorb, count_in_window). First two occurrences of a
    fingerprint inside the window escalate (state changes stay visible); the
    third and later absorb. Window is 3600s, same as the old rate limiter.
    """
    now = time.time()
    fp = normalize_fingerprint(alert_text)
    key = "fp:" + hashlib.sha256(fp.encode("utf-8")).hexdigest()[:16]
    cache_path = get_cache_path()
    try:
        data = json.loads(cache_path.read_text(encoding="utf-8"))
    except Exception:
        data = {}

    entry = data.get(key, {})
    if now - float(entry.get("last_seen", 0)) > 3600:
        entry = {"first_seen": now, "last_seen": now, "count": 1}
    else:
        entry["last_seen"] = now
        entry["count"] = int(entry.get("count", 0)) + 1
    data[key] = entry
    try:
        cache_path.write_text(json.dumps(data), encoding="utf-8")
    except Exception:
        pass

    count = entry["count"]
    return count > 2, count


def correlate_with_jev(
    alert_text: str,
    source: str,
    active_holds: list[str],
    key: str,
    repeat_count: int = 1,
) -> tuple[str, str, str, str]:
    """Tier 3: Semantic correlation with Jev System One."""
    payload = {
        "model": TS_MODEL,
        "state": {
            "alert": alert_text[:400],
            "source": source,
            "active_holds": "\n".join(active_holds[:5]) if active_holds else "none (no active holds)",
            "repeat_context": (
                f"This fingerprint of the alert has already been seen {repeat_count - 1} "
                "time(s) in the last hour with only counter/timestamp differences."
            ),
        },
        "questions": {
            "incident_status": {
                "type": "choice",
                "instructions": "Compare the alert to the active holds and the repeat context. Is this a held/known condition, or an unrelated new production failure? When the holds list is empty, judge on the alert text alone: monitoring noise and repeats of an already-seen condition are not new incidents.",
                "criteria": {
                    "known_held_issue": {
                        "definition": "The alert specifically mentions a service, component, or error described in the active holds.",
                        "example": "alert says email_ingest heartbeat stale while an email_ingest hold is active",
                    },
                    "reconciled_inactive_failure": {
                        "definition": "A known, previously reconciled diagnostic, cursor repeat, or repeat of an already-seen condition.",
                        "example": "same stack-monitor critical line seen repeatedly with only open=N counters changing",
                    },
                    "new_actionable_outage": {
                        "definition": "An unhandled, separate production failure NOT described by any hold and not a repeat.",
                        "example": "first sighting of 'postgres primary unreachable' with no hold covering it",
                    },
                },
            },
            "novelty_noul": {
                "type": "noul",
                "instructions": "Probability this alert reports a genuine new production problem that is NOT a repeat or covered by active holds.",
            },
            "route_target": {
                "type": "choice",
                "instructions": "Which seat should own this alert if it is escalated?",
                "criteria": {
                    "monitor_sre": "Stack monitoring, health checks, uptime alerts, watcher/wake signals.",
                    "svc_ops": "Services, systemd, web server, Redis, reverse proxy, portal infra on srv-covenant-app or svc.",
                    "gpu_ops": "GPU host operations, Ollama, STT, whisper, models, CUDA, host config on gpu.",
                    "firstmate_upstream": "Firstmate framework or upstream pull request problems.",
                    "supervisor": "Firstmate's own supervision queue; no secondmate seat owns it.",
                },
            },
        },
    }

    req = urllib.request.Request(
        f"{TS_BASE}/v1/systemone",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=TS_TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        answers = data.get("answers", {})
        status_choice = answers.get("incident_status", {}).get("choice", "new_actionable_outage")
        novelty_noul = float(answers.get("novelty_noul", {}).get("noul", 1.0))
        route = answers.get("route_target", {}).get("choice", "supervisor")
        detail = f"choice={status_choice} novelty={novelty_noul:.2f} route={route}"

        if status_choice in ("known_held_issue", "reconciled_inactive_failure"):
            return "absorb", status_choice, f"Jev correlated alert to {status_choice} (novelty={novelty_noul:.2f})", detail
        elif status_choice == "new_actionable_outage" or novelty_noul >= 0.5:
            return "escalate", "new_incident", f"Jev confirmed actionable outage ({status_choice}, novelty={novelty_noul:.2f}, route={route})", detail
        else:
            return "absorb", "low_novelty", f"Jev absorbed low-novelty alert ({status_choice}, novelty={novelty_noul:.2f})", detail
    except Exception as exc:
        # Fail-open: escalate on API error
        return "escalate", "jev_fail_open", f"Jev API timeout/error ({exc}); escalating safely", f"fail_open={type(exc).__name__}"


def main() -> None:
    parser = argparse.ArgumentParser(description="Jev Semantic Alert Correlator")
    parser.add_argument("--alert", required=True, help="Alert text to correlate")
    parser.add_argument("--source", default="check", help="Alert source name")
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    args = parser.parse_args()

    fm_root = Path(os.environ.get("FM_HOME", "/opt/ra/firstmate"))
    state_dir = Path(os.environ.get("FM_STATE_OVERRIDE", fm_root / "state"))

    # 1. Tier 1 Static Hold Matching
    active_holds = load_active_holds(state_dir)
    lower_alert = args.alert.lower()
    for hold in active_holds:
        lower_hold = hold.lower()
        # Look for matching components like email_ingest, advisor, codex
        if "email_ingest" in lower_alert and "email_ingest" in lower_hold:
            emit_result("absorb", "active_email_ingest_hold", "Alert matches active email ingest hold", "tier1", args.source, args.alert, args.json, exit_code=0)
        if "codex" in lower_alert and "codex" in lower_hold:
            emit_result("absorb", "active_codex_hold", "Alert matches active Codex login hold", "tier1", args.source, args.alert, args.json, exit_code=0)

    # 2. Tier 1b Fingerprint dampening: same normalized alert (counters/timestamps
    #    ignored) seen 3+ times inside the hour is absorbed, not re-paged.
    is_repeat, repeat_count = check_fingerprint_dampen(args.alert)
    if is_repeat:
        emit_result(
            "absorb",
            "repeat_fingerprint_dampened",
            f"Same alert fingerprint seen {repeat_count} times within the hour (state unchanged)",
            "tier1",
            args.source,
            args.alert,
            args.json,
            exit_code=0,
            detail=f"fingerprint_repeats={repeat_count}",
        )

    # 3. Tier 3 Semantic Jev Correlation
    key = get_api_key()
    if key:
        action, code, reason, detail = correlate_with_jev(
            args.alert, args.source, active_holds, key, repeat_count=repeat_count
        )
        exit_code = 0 if action == "absorb" else 2
        emit_result(action, code, reason, "tier3", args.source, args.alert, args.json, exit_code=exit_code, detail=detail)

    # Default fallback: escalate so Firstmate is aware
    emit_result("escalate", "unmatched_alert", "Alert does not match any known hold", "tier1", args.source, args.alert, args.json, exit_code=2)


if __name__ == "__main__":
    main()
