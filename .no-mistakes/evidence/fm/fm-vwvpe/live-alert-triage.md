# Live alert-triage drives

## 1) fm-jev-wake-triage.sh with no credential: fail-open contract, watcher still escalates, telemetry stamped
```console
action=unavailable
class=ship
exit=0
--- state/.jev-triage-telemetry ---
jev_triage.unavailable	ship
--- state/.jev-triage-calibration.jsonl (first decision logged) ---
{"n":1,"class":"ship","action":"unavailable","choice":null,"noul":null,"outcome":"unavailable","summary":{"task_id":"demo-z1","kind":"ship","idle_seconds":600,"escalation_count":3,"last_status":"","status_tail":[],"run_step":""}}
```

## 2) usage errors are the only non-zero exit
```console
error: --age is required
exit=2
```

## 3) fm-jev-alert-correlator.sh with no credential: observable fail-open answer, no crash
```console
{
  "action": "escalate",
  "code": "unmatched_alert",
  "reason": "Alert does not match any known hold",
  "tier": "tier1",
  "source": "lab-test"
}
exit=2
```

## 4) Tier-1 suppression live: an alert matching a real active captain hold is absorbed (exit 0)
```console
DECISION: absorb [active_email_ingest_hold] Alert matches active email ingest hold
exit=0
--- state/.jev-alert-telemetry ---
2026-09-27T16:54:23Z	escalate	tier1	unmatched_alert	lab-test	gpu disk usage at 95% on /home
2026-09-27T16:54:49Z	absorb	tier1	active_email_ingest_hold	lab-test	stack-monitor critical: email_ingest heartbeat stale (age_ms=88354348)
```

## 5) novel alert still pages (escalate, exit 2) - suppression never swallows a new outage
```console
DECISION: escalate [unmatched_alert] Alert does not match any known hold
exit=2
```
