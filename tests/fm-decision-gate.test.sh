#!/usr/bin/env bash
# fm-decision-gate.test.sh - Scope Area 3: JEV Classifier and Deny-on-Missing Seam tests.
#
# SI Control Phase 3:
#   1. Implement Section 4.5: Deny-on-missing-decision rule at the DEPLOY seam.
#   2. JEV is intelligence/classifier only: never a grantor, advisory only.
#   3. Decision verification requirements:
#      - Present, well-formed decision=allow record
#      - Exact normalized action and target match
#      - Bound to task identity (FM_TASK_ID)
#      - Bound to SHA-256 payload hash at approval time
#      - Unexpired (now <= expires_at)
#      - One-use semantics (used_at atomically stamped, replay denied)
#      - Human captain approval reference required (JEV cannot grant)
#      - JEV confidence meets or exceeds floor (0.80)
#   4. Evidence collection: all outcomes (ALLOW, DENY, missing-decision) recorded in ledger.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

DEPLOY_GATE="$ROOT/bin/fm-deploy-gate.sh"
JEV_CLASSIFY="$ROOT/bin/fm-jev-classify.sh"
LABHOME="$ROOT/bin/fm-lab-home.sh"

TMP=$(fm_test_tmproot fm-decision-gate)

# Create marked lab home
LAB="$TMP/labhome"
bash "$LABHOME" create "$LAB" >/dev/null 2>&1 || fail "fm-lab-home create failed"

# Prepare test payload
PAYLOAD="$TMP/covenant-deploy.tar.gz"
echo "covenant-app-release-v2.0.0" > "$PAYLOAD"
PAYLOAD_HASH=$(sha256sum "$PAYLOAD" | awk '{print $1}')

TASK_ID="fm-task-deploy-001"
TARGET="srv-covenant-app"
ACTION="deploy"
FUTURE=$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+1d +%Y-%m-%dT%H:%M:%SZ)

# Function to generate test decision records
make_decision_record() {
  local outfile=$1
  local decision=${2:-allow}
  local approval=${3:-"captain-approval-token-001"}
  local hash=${4:-$PAYLOAD_HASH}
  local exp=${5:-"$FUTURE"}
  local used=${6:-null}
  local conf=${7:-0.95}
  local risk=${8:-not_risky}
  local task=${9:-$TASK_ID}
  local act=${10:-$ACTION}
  local tgt=${11:-$TARGET}

  jq -nc \
    --arg dec_id "dec-$(date +%s%N)" \
    --arg actor "firstmate-agent" \
    --arg task "$task" \
    --arg trace "4bf92f3577b34da6a3ce929d0e0e4736" \
    --arg target "$tgt" \
    --arg action "$act" \
    --arg hash "$hash" \
    --arg exp "$exp" \
    --arg used "$used" \
    --arg decision "$decision" \
    --arg approval "$approval" \
    --arg risk "$risk" \
    --argjson conf "$conf" \
    '{
      decision_id: $dec_id,
      actor: $actor,
      task_id: $task,
      trace_id: $trace,
      target: $target,
      action: $action,
      arguments: { environment: "production", service: "covenant-app" },
      payload_hash: $hash,
      policy_version: "2026-10-12",
      expires_at: $exp,
      used_at: (if $used == "null" then null else $used end),
      decision: $decision,
      approval_reference: (if $approval == "null" then null else $approval end),
      jev_classification: {
        risk_label: $risk,
        confidence: $conf,
        reason: "JEV advisory review"
      }
    }' > "$outfile"
}

REC_VALID_BASE="$TMP/valid-base.json"

# 1. Deny-on-missing: Absent record fails closed
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID="$TASK_ID" \
  bash "$DEPLOY_GATE" check "$TARGET" "$PAYLOAD" "$TMP/nonexistent-record.json" >/dev/null 2>&1 && fail "absent record must DENY"
pass "deploy seam: absent record DENIES (fail closed)"

# 2. Deny-on-missing: Empty or truncated record fails closed
TRUNCATED="$TMP/truncated.json"
echo "" > "$TRUNCATED"
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID="$TASK_ID" \
  bash "$DEPLOY_GATE" check "$TARGET" "$PAYLOAD" "$TRUNCATED" >/dev/null 2>&1 && fail "empty record must DENY"
pass "deploy seam: empty record DENIES"

# 3. Deny-on-missing: Malformed JSON fails closed
MALFORMED="$TMP/malformed.json"
echo "{\"decision_id\": \"test\", malformed" > "$MALFORMED"
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID="$TASK_ID" \
  bash "$DEPLOY_GATE" check "$TARGET" "$PAYLOAD" "$MALFORMED" >/dev/null 2>&1 && fail "malformed record must DENY"
pass "deploy seam: malformed JSON DENIES"

# 4. Deny-on-missing: Action mismatch fails closed
REC_ACTION_MISMATCH="$TMP/action-mismatch.json"
make_decision_record "$REC_ACTION_MISMATCH" allow "token" "$PAYLOAD_HASH" "$FUTURE" null 0.95 not_risky "$TASK_ID" "restart"
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID="$TASK_ID" \
  bash "$DEPLOY_GATE" check "$TARGET" "$PAYLOAD" "$REC_ACTION_MISMATCH" >/dev/null 2>&1 && fail "action mismatch must DENY"
pass "deploy seam: action mismatch DENIES"

# 5. Deny-on-missing: Target mismatch fails closed
REC_TARGET_MISMATCH="$TMP/target-mismatch.json"
make_decision_record "$REC_TARGET_MISMATCH" allow "token" "$PAYLOAD_HASH" "$FUTURE" null 0.95 not_risky "$TASK_ID" "$ACTION" "srv-other-app"
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID="$TASK_ID" \
  bash "$DEPLOY_GATE" check "$TARGET" "$PAYLOAD" "$REC_TARGET_MISMATCH" >/dev/null 2>&1 && fail "target mismatch must DENY"
pass "deploy seam: target mismatch DENIES"

# 6. Payload binding: Tampered payload after approval fails closed
REC_TAMPERED="$TMP/tampered-rec.json"
make_decision_record "$REC_TAMPERED" allow "token" "$PAYLOAD_HASH"
TAMPERED_PAYLOAD="$TMP/tampered.tar.gz"
echo "tampered-payload-bytes" > "$TAMPERED_PAYLOAD"
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID="$TASK_ID" \
  bash "$DEPLOY_GATE" check "$TARGET" "$TAMPERED_PAYLOAD" "$REC_TAMPERED" >/dev/null 2>&1 && fail "tampered payload must DENY"
pass "deploy seam: tampered payload hash DENIES"

# 7. Expiry check: Expired record fails closed
REC_EXPIRED="$TMP/expired-rec.json"
make_decision_record "$REC_EXPIRED" allow "token" "$PAYLOAD_HASH" "2025-01-01T00:00:00Z"
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID="$TASK_ID" \
  bash "$DEPLOY_GATE" check "$TARGET" "$PAYLOAD" "$REC_EXPIRED" >/dev/null 2>&1 && fail "expired record must DENY"
pass "deploy seam: expired record DENIES"

# 8. One-use semantics: Replayed record fails closed
REC_REPLAY="$TMP/replay-rec.json"
make_decision_record "$REC_REPLAY" allow "token" "$PAYLOAD_HASH" "$FUTURE" "2026-10-13T05:30:00Z"
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID="$TASK_ID" \
  bash "$DEPLOY_GATE" check "$TARGET" "$PAYLOAD" "$REC_REPLAY" >/dev/null 2>&1 && fail "replayed record must DENY"
pass "deploy seam: replayed record DENIES"

# 9. JEV Authority Boundary: JEV alone cannot grant allow
REC_JEV_ONLY="$TMP/jev-only-rec.json"
make_decision_record "$REC_JEV_ONLY" allow "null" "$PAYLOAD_HASH"
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID="$TASK_ID" \
  bash "$DEPLOY_GATE" check "$TARGET" "$PAYLOAD" "$REC_JEV_ONLY" >/dev/null 2>&1 && fail "JEV alone without captain approval must DENY"
pass "deploy seam: JEV alone without human approval DENIES (JEV cannot grant)"

# 10. JEV confidence floor enforcement
REC_LOW_CONF="$TMP/low-conf-rec.json"
make_decision_record "$REC_LOW_CONF" allow "token" "$PAYLOAD_HASH" "$FUTURE" null 0.75
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID="$TASK_ID" \
  bash "$DEPLOY_GATE" check "$TARGET" "$PAYLOAD" "$REC_LOW_CONF" >/dev/null 2>&1 && fail "confidence 0.75 < 0.80 floor must DENY"
pass "deploy seam: JEV confidence below 0.80 floor DENIES"

# 10b. A non-numeric JEV confidence is outside the schema and DENIES
REC_TEXT_CONF="$TMP/text-conf-rec.json"
make_decision_record "$REC_VALID_BASE" allow "token" "$PAYLOAD_HASH"
jq '.jev_classification.confidence = "high"' "$REC_VALID_BASE" > "$REC_TEXT_CONF"
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID="$TASK_ID" \
  bash "$DEPLOY_GATE" check "$TARGET" "$PAYLOAD" "$REC_TEXT_CONF" >/dev/null 2>&1 && fail "non-numeric confidence must DENY"
pass "deploy seam: non-numeric JEV confidence DENIES"

# 10c. Missing or unparseable expiry DENIES
for exp_edit in 'del(.expires_at)' '.expires_at = "never"'; do
  REC_BAD_EXP="$TMP/bad-exp-rec.json"
  jq "$exp_edit" "$REC_VALID_BASE" > "$REC_BAD_EXP"
  env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID="$TASK_ID" \
    bash "$DEPLOY_GATE" check "$TARGET" "$PAYLOAD" "$REC_BAD_EXP" >/dev/null 2>&1 && fail "expiry edit '$exp_edit' must DENY"
done
pass "deploy seam: missing or unparseable expiry DENIES"

# 10d. Fractional-second expiry in the future is accepted
REC_FRAC_EXP="$TMP/frac-exp-rec.json"
jq --arg exp "${FUTURE%Z}.000Z" '.expires_at = $exp' "$REC_VALID_BASE" > "$REC_FRAC_EXP"
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID="$TASK_ID" \
  bash "$DEPLOY_GATE" check "$TARGET" "$PAYLOAD" "$REC_FRAC_EXP" >/dev/null 2>&1 || fail "future fractional-second expiry should pass"
pass "deploy seam: fractional-second expiry parses"

# 10e. Task identity is required on both sides
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID= \
  bash "$DEPLOY_GATE" check "$TARGET" "$PAYLOAD" "$REC_VALID_BASE" >/dev/null 2>&1 && fail "unset FM_TASK_ID must DENY"
REC_NO_TASK="$TMP/no-task-rec.json"
jq 'del(.task_id)' "$REC_VALID_BASE" > "$REC_NO_TASK"
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID="$TASK_ID" \
  bash "$DEPLOY_GATE" check "$TARGET" "$PAYLOAD" "$REC_NO_TASK" >/dev/null 2>&1 && fail "record without task_id must DENY"
pass "deploy seam: missing task identity DENIES"

# 10f. Policy version must match the version in force
REC_OLD_POLICY="$TMP/old-policy-rec.json"
jq '.policy_version = "2020-01-01"' "$REC_VALID_BASE" > "$REC_OLD_POLICY"
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID="$TASK_ID" \
  bash "$DEPLOY_GATE" check "$TARGET" "$PAYLOAD" "$REC_OLD_POLICY" >/dev/null 2>&1 && fail "policy version mismatch must DENY"
pass "deploy seam: policy version mismatch DENIES"

# 10g. Concurrent executes of one record run the deploy at most once
REC_RACE="$TMP/race-rec.json"
make_decision_record "$REC_RACE" allow "captain-approval-race" "$PAYLOAD_HASH"
RACE_LOG="$TMP/race-deploys.log"
: > "$RACE_LOG"
# shellcheck disable=SC2016
for _ in 1 2 3 4 5 6 7 8; do
  env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID="$TASK_ID" \
    bash "$DEPLOY_GATE" execute "$TARGET" "$PAYLOAD" "$REC_RACE" sh -c 'echo deployed >> "$1"' sh "$RACE_LOG" >/dev/null 2>&1 &
done
wait
race_runs=$(wc -l < "$RACE_LOG")
[ "$race_runs" -eq 1 ] || fail "one allow record authorized $race_runs concurrent deploys"
race_denies=$(jq -c --arg r "$REC_RACE" 'select(.record == $r and .outcome == "DENY")' \
  "$LAB/state/evidence/decisions/decision-ledger.jsonl" | wc -l)
[ "$race_denies" -eq 7 ] || fail "ledger recorded $race_denies DENY entries for 7 refused concurrent executes"
pass "deploy seam: concurrent executes consume a record exactly once"

# 11. Valid allow record ALLOWS and consumes one-use token
REC_VALID="$TMP/valid-exec.json"
make_decision_record "$REC_VALID" allow "captain-approval-valid" "$PAYLOAD_HASH"

# First check: passes
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID="$TASK_ID" \
  bash "$DEPLOY_GATE" check "$TARGET" "$PAYLOAD" "$REC_VALID" >/dev/null 2>&1 || fail "valid allow record should pass check"
pass "deploy seam: valid unexpired one-use allow record PASSES check"

# Execute: passes and marks used_at
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID="$TASK_ID" \
  bash "$DEPLOY_GATE" execute "$TARGET" "$PAYLOAD" "$REC_VALID" echo "deployed" >/dev/null 2>&1 || fail "valid execution failed"
pass "deploy seam: execution succeeds with valid allow record"

used_stamp=$(jq -r '.used_at // empty' "$REC_VALID")
[ -n "$used_stamp" ] || fail "execution failed to stamp used_at"
pass "deploy seam: execution stamps used_at timestamp"

# Subsequent execution: immediately DENIES
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 FM_TASK_ID="$TASK_ID" \
  bash "$DEPLOY_GATE" execute "$TARGET" "$PAYLOAD" "$REC_VALID" echo "redeployed" >/dev/null 2>&1 && fail "consumed record must DENY on replay"
pass "deploy seam: immediate replay DENIES"

# 12. Evidence ledger recording
LEDGER="$LAB/state/evidence/decisions/decision-ledger.jsonl"
[ -f "$LEDGER" ] || fail "decision evidence ledger was not created"
entries=$(wc -l < "$LEDGER")
[ "$entries" -ge 10 ] || fail "expected at least 10 evidence entries in ledger, found $entries"
pass "decision evidence ledger records all allow and deny decisions with reasons"

# 13. JEV Classifier CLI tests
# Non-risky payload
CLASSIFY_OUT=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$JEV_CLASSIFY" deploy staging "$PAYLOAD")
jq -e '.risk_label == "not_risky" and .advisory_only == true and (.decision == null)' <<< "$CLASSIFY_OUT" >/dev/null 2>&1 || fail "JEV classifier output invalid"
pass "fm-jev-classify.sh classifies staging deploy as not_risky and remains advisory-only"

# Destructive payload
DEST_PAYLOAD="$TMP/drop-db.sql"
echo "DROP TABLE users;" > "$DEST_PAYLOAD"
DEST_OUT=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$JEV_CLASSIFY" deploy production "$DEST_PAYLOAD")
jq -e '.risk_label == "risky" and .advisory_only == true' <<< "$DEST_OUT" >/dev/null 2>&1 || fail "destructive SQL must be flagged as risky"
pass "fm-jev-classify.sh flags destructive payload as risky"

echo "ok: Scope Area 3 JEV classifier and deny-on-missing tests passed completely"
