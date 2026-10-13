#!/usr/bin/env bash
# fm-si-control-p3-testenv.test.sh - Scope Area 2: Isolated Test Environment & Bypass Matrix.
#
# SI Control Phase 3:
#   1. Synthetic fixture hygiene: no PHI, no credentials, valid schemas.
#   2. Disposable lab home and gate-refuse coverage for all Phase 3 mutation entrypoints.
#   3. Full bypass matrix: deploy seam, JEV advisory authority, GUI containment.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

DEPLOY_GATE="$ROOT/bin/fm-deploy-gate.sh"
GUI_ROUTER="$ROOT/bin/fm-gui-router.sh"
JEV_CLASSIFY="$ROOT/bin/fm-jev-classify.sh"
OBS_RECORD="$ROOT/bin/fm-observation-record.sh"
OBS_SHIPPER="$ROOT/bin/fm-observation-spool-shipper.sh"
LABHOME="$ROOT/bin/fm-lab-home.sh"

TMP=$(fm_test_tmproot fm-si-p3-testenv)
FIXTURES_DIR="$ROOT/tests/fixtures/si-control-p3"

# --- 1. Synthetic Fixture Validation ---------------------------------------

# All fixtures exist
for f in observation-metadata.json policy-decision-record.json jev-classifier.json gui-containment-map.json; do
  [ -f "$FIXTURES_DIR/$f" ] || fail "fixture $f is missing"
done
pass "all 4 Phase 3 synthetic fixtures exist"

# Validate JSON well-formedness
for f in "$FIXTURES_DIR"/*.json; do
  jq -e . "$f" >/dev/null 2>&1 || fail "fixture $f is not valid JSON"
done
pass "all Phase 3 synthetic fixtures parse as valid JSON"

# Strict PHI / Secret absence assertion across all fixtures
for f in "$FIXTURES_DIR"/*.json; do
  if grep -i -E "password|secret|bearer\s+|mrn|ssn|patient_id|@.*\.com" "$f" 2>/dev/null; then
    fail "fixture $f contains forbidden sensitive tokens or identifiers"
  fi
done
pass "all Phase 3 synthetic fixtures are strictly PHI and credential-free"

# Observation metadata fixture conforms to Section 2.3 schema
jq -e '
  .identity.task_id != null and
  .identity.trace_id != null and
  .identity.span_id != null and
  .identity.runtime_identity.harness == "pi" and
  .call.provider != null and
  .call.model != null and
  .call.duration_ms >= 0 and
  .call.status == "ok" and
  .usage.input_tokens >= 0 and
  .usage.output_tokens >= 0 and
  .retention.retention_policy_class != null
' "$FIXTURES_DIR/observation-metadata.json" >/dev/null 2>&1 || fail "observation-metadata.json schema mismatch"
pass "observation metadata fixture matches Section 2.3 schema"

# Policy decision record conforms to Sections 4.4 and 4.5
jq -e '
  .decision_id != null and
  .action == "deploy" and
  .target != null and
  .payload_hash != null and
  .decision == "allow" and
  .approval_reference != null and
  .jev_classification.risk_label != null and
  .used_at == null
' "$FIXTURES_DIR/policy-decision-record.json" >/dev/null 2>&1 || fail "policy-decision-record.json schema mismatch"
pass "policy decision record matches Sections 4.4 and 4.5 schema"

# JEV classifier fixture is strictly advisory (advisory_only: true, no decision=allow)
jq -e '
  .advisory_only == true and
  .risk_label != null and
  .confidence != null and
  (.decision == null)
' "$FIXTURES_DIR/jev-classifier.json" >/dev/null 2>&1 || fail "jev-classifier.json must be advisory-only"
pass "JEV classifier fixture is strictly advisory and cannot grant allow"

# GUI containment map fixture has allowlisted hosts and blocked contexts
jq -e '
  .allowed_hosts != null and
  .contexts.agt_auto_deploy.account_type == "automation" and
  .blocked_contexts.captain_personal.account_type == "personal"
' "$FIXTURES_DIR/gui-containment-map.json" >/dev/null 2>&1 || fail "gui-containment-map.json schema mismatch"
pass "GUI containment map fixture defines automation allowlists and blocks personal contexts"

# --- 2. Lab Home & Gate-Refuse Coverage ------------------------------------

LAB="$TMP/labhome"
bash "$LABHOME" create "$LAB" >/dev/null 2>&1 || fail "fm-lab-home create failed"
[ -f "$LAB/.fm-lab-home" ] || fail "lab home marker missing"
pass "disposable lab home created and marked"

# Test entrypoints under NO_MISTAKES_GATE=1 against real fleet (must refuse with exit 3)
for script in "$DEPLOY_GATE" "$GUI_ROUTER" "$JEV_CLASSIFY" "$OBS_RECORD" "$OBS_SHIPPER"; do
  sname=$(basename "$script")
  out=$(env NO_MISTAKES_GATE=1 FM_HOME="$TMP/unmarked" FM_GATE_REFUSE_BYPASS="" bash "$script" 2>&1 || true)
  if [ "${out#*no-mistakes gate agent must not drive the fleet}" = "$out" ]; then
    fail "$sname did not refuse under NO_MISTAKES_GATE=1 (output: $out)"
  fi
done
pass "all Phase 3 entrypoints refuse fleet mutation under NO_MISTAKES_GATE=1"

# Inside marked lab home, gate agent is permitted
out=$(env NO_MISTAKES_GATE=1 FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS="" bash "$OBS_RECORD" write mock-prov mock-mod 100 10 20 2>&1 || true)
if [ "${out#*gate agent lifecycle permitted only against lab home}" = "$out" ]; then
  fail "fm-observation-record failed to permit marked lab home (output: $out)"
fi
pass "marked disposable lab home is permitted for Phase 3 lifecycle"

# FM_*_OVERRIDE defeats the lab home allowance
out=$(env NO_MISTAKES_GATE=1 FM_HOME="$LAB" FM_STATE_OVERRIDE="$TMP/split" FM_GATE_REFUSE_BYPASS="" bash "$OBS_RECORD" write mock-prov mock-mod 100 10 20 2>&1 || true)
if [ "${out#*no-mistakes gate agent must not drive the fleet}" = "$out" ]; then
  fail "FM_STATE_OVERRIDE did not defeat lab home allowance"
fi
pass "FM_*_OVERRIDE correctly defeats lab home allowance"

# --- 3. Bypass Matrix: Deploy Seam Deny-on-Missing Gate --------------------

PAYLOAD="$TMP/deploy-payload.tar.gz"
echo "synthetic-deploy-payload-bytes" > "$PAYLOAD"
PAYLOAD_HASH=$(sha256sum "$PAYLOAD" | awk '{print $1}')

# Setup test decision records
VALID_RECORD="$TMP/valid-record.json"
jq --arg hash "$PAYLOAD_HASH" '.payload_hash = $hash' "$FIXTURES_DIR/policy-decision-record.json" > "$VALID_RECORD"

# Case A: Missing decision record -> DENY
env FM_GATE_REFUSE_BYPASS=1 bash "$DEPLOY_GATE" check srv-covenant-app "$PAYLOAD" "$TMP/nonexistent.json" >/dev/null 2>&1 && fail "missing decision record must DENY"
pass "deploy seam: missing decision record DENIES"

# Case B: Malformed decision record -> DENY
MALFORMED_RECORD="$TMP/malformed.json"
echo "{invalid json" > "$MALFORMED_RECORD"
env FM_GATE_REFUSE_BYPASS=1 bash "$DEPLOY_GATE" check srv-covenant-app "$PAYLOAD" "$MALFORMED_RECORD" >/dev/null 2>&1 && fail "malformed decision record must DENY"
pass "deploy seam: malformed decision record DENIES"

# Case C: Payload changed after approval -> DENY
TAMPERED_PAYLOAD="$TMP/tampered-payload.tar.gz"
echo "tampered-different-bytes" > "$TAMPERED_PAYLOAD"
env FM_GATE_REFUSE_BYPASS=1 bash "$DEPLOY_GATE" check srv-covenant-app "$TAMPERED_PAYLOAD" "$VALID_RECORD" >/dev/null 2>&1 && fail "payload changed after approval must DENY"
pass "deploy seam: tampered payload DENIES"

# Case D: Expired decision record -> DENY
EXPIRED_RECORD="$TMP/expired.json"
jq '.expires_at = "2020-01-01T00:00:00Z"' "$VALID_RECORD" > "$EXPIRED_RECORD"
env FM_GATE_REFUSE_BYPASS=1 bash "$DEPLOY_GATE" check srv-covenant-app "$PAYLOAD" "$EXPIRED_RECORD" >/dev/null 2>&1 && fail "expired decision record must DENY"
pass "deploy seam: expired record DENIES"

# Case E: Already used decision record -> DENY
USED_RECORD="$TMP/used.json"
jq '.used_at = "2026-10-13T05:00:00Z"' "$VALID_RECORD" > "$USED_RECORD"
env FM_GATE_REFUSE_BYPASS=1 bash "$DEPLOY_GATE" check srv-covenant-app "$PAYLOAD" "$USED_RECORD" >/dev/null 2>&1 && fail "already used record must DENY"
pass "deploy seam: replayed record DENIES"

# Case F: JEV alone without human approval_reference -> DENY (JEV cannot grant allow)
JEV_ONLY_RECORD="$TMP/jev-only.json"
jq '.approval_reference = null' "$VALID_RECORD" > "$JEV_ONLY_RECORD"
env FM_GATE_REFUSE_BYPASS=1 bash "$DEPLOY_GATE" check srv-covenant-app "$PAYLOAD" "$JEV_ONLY_RECORD" >/dev/null 2>&1 && fail "JEV-only record without captain approval must DENY"
pass "deploy seam: JEV alone cannot grant allow (DENIES)"

# Case G: Low confidence JEV classification -> DENY
LOW_CONF_RECORD="$TMP/low-conf.json"
jq '.jev_classification.confidence = 0.50' "$VALID_RECORD" > "$LOW_CONF_RECORD"
env FM_GATE_REFUSE_BYPASS=1 bash "$DEPLOY_GATE" check srv-covenant-app "$PAYLOAD" "$LOW_CONF_RECORD" >/dev/null 2>&1 && fail "low confidence JEV classification must DENY"
pass "deploy seam: low JEV confidence DENIES"

# Case H: Valid allow record -> ALLOW and one-use consumption
EXEC_RECORD="$TMP/exec-record.json"
cp "$VALID_RECORD" "$EXEC_RECORD"
env FM_GATE_REFUSE_BYPASS=1 bash "$DEPLOY_GATE" execute srv-covenant-app "$PAYLOAD" "$EXEC_RECORD" >/dev/null 2>&1 || fail "valid allow record must execute"
pass "deploy seam: valid unexpired one-use record ALLOWS"

# Assert used_at was stamped
used_ts=$(jq -r '.used_at // empty' "$EXEC_RECORD")
[ -n "$used_ts" ] || fail "used_at was not stamped on execution"
pass "deploy seam: execution stamps used_at atomically"

# Attempting to reuse consumed record -> DENY
env FM_GATE_REFUSE_BYPASS=1 bash "$DEPLOY_GATE" execute srv-covenant-app "$PAYLOAD" "$EXEC_RECORD" >/dev/null 2>&1 && fail "reused record must DENY"
pass "deploy seam: second execution with consumed record DENIES"

# --- 4. Bypass Matrix: GUI Containment Router ------------------------------

GUI_MAP="$FIXTURES_DIR/gui-containment-map.json"

# Case A: Personal browser session -> REFUSE
env FM_GATE_REFUSE_BYPASS=1 bash "$GUI_ROUTER" check "$GUI_MAP" "captain_personal" "mbp" >/dev/null 2>&1 && fail "personal context must REFUSE"
pass "gui router: personal browser session REFUSES"

# Case B: Unmapped context alias -> REFUSE
env FM_GATE_REFUSE_BYPASS=1 bash "$GUI_ROUTER" check "$GUI_MAP" "unmapped_alias" "mbp" >/dev/null 2>&1 && fail "unmapped alias must REFUSE"
pass "gui router: unmapped alias REFUSES"

# Case C: Non-allowlisted host -> REFUSE
env FM_GATE_REFUSE_BYPASS=1 bash "$GUI_ROUTER" check "$GUI_MAP" "agt_auto_deploy" "rogue-host" >/dev/null 2>&1 && fail "non-allowlisted host must REFUSE"
pass "gui router: non-allowlisted host REFUSES"

# Case D: Host mismatch for alias -> REFUSE
env FM_GATE_REFUSE_BYPASS=1 bash "$GUI_ROUTER" check "$GUI_MAP" "agt_auto_deploy" "agt-8" >/dev/null 2>&1 && fail "host context mismatch must REFUSE"
pass "gui router: host mismatch REFUSES"

# Case E: Valid automation context -> ALLOW
env FM_GATE_REFUSE_BYPASS=1 bash "$GUI_ROUTER" check "$GUI_MAP" "agt_auto_deploy" "agt-2" >/dev/null 2>&1 || fail "valid automation context must ALLOW"
pass "gui router: valid automation context ALLOWS"

# --- 5. JEV Classifier Advisory Tests -------------------------------------

# Destructive payload detected as risky
DEST_PAYLOAD="$TMP/dest-payload.sh"
echo "sudo rm -rf /var/log" > "$DEST_PAYLOAD"
out=$(env FM_GATE_REFUSE_BYPASS=1 bash "$JEV_CLASSIFY" deploy production "$DEST_PAYLOAD")
risk=$(printf '%s' "$out" | jq -r '.risk_label')
adv=$(printf '%s' "$out" | jq -r '.advisory_only')
[ "$risk" = "risky" ] || fail "destructive payload must be classified as risky"
[ "$adv" = "true" ] || fail "JEV classifier must report advisory_only=true"
pass "JEV classifier flags destructive payload as risky and stays advisory"

echo "ok: Scope Area 2 isolated test environment and bypass matrix passed completely"
