# Scenario 21 evidence record — test-phase evidence (fix/si-scenario21, e7f79e8e)

Change under test: one new file, docs/si-control/evidence/scenario-21.json.

Files here:
- scenario21-source-comparison.txt — programmatic diff of the public record against the private
  probe result.json, extension-recapture-public.json and the raw recapture transcript
  (SHA-256 of probe.py and transcript match probe_sha256 / private_capture_sha256).
  Agent and local-model items identical to result.json; extension item identical to the
  publication-safe recapture item; timestamps, browser version, 45 launch args and the zero
  extension count match the raw transcript token for token with only three path-bearing
  values withheld. Kernel, username, /home and /opt paths and the seat/task id are absent.
- json-validity-and-audience-check.txt — python json + jq consumers parse the record;
  `bash bin/fm-doc-audience-check.sh` exits 0.
- live-gate-negative-control.txt — the gate_negative_control re-driven live: worktree
  bin/fm-action-gate.sh copied to a read-only disposable git-pinned install, FM_HOME = a
  marked disposable lab home (bin/fm-lab-home.sh create), effect command replaced by
  `touch <marker>`. Result: exit 1, "DENY: real mail send is strictly prohibited; only
  drafts are permitted" + "execution refused", marker never created. Same for a fabricated
  grant file, the `send` alias, and `check`. Only difference from the recorded stderr is one
  extra leading line "fm-gate-refuse: gate agent lifecycle permitted only against lab home",
  emitted because this run is a gate agent using the lab-home allowance; the probe ran
  outside a gate context. Lab removed after capture.
