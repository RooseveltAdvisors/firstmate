#!/usr/bin/env bash
# tests/fm-action-gate.test.sh - unit and regression tests for Phase 4 action gate.
#
# Tests the single protected executor for consequential actions:
#   1. Deny-by-default for booking/charging without a grant (routes to review).
#   2. Real mail send denied always, draft permitted.
#   3. prod_deploy requires one-time human grant and is denied without it.
#   4. Runner cannot mint its own grants.
#   5. Evidence records are written to an append-only ledger.
#   6. JEV risk flags route to human review and JEV cannot grant allow.
#   7. Atomic one-use consumption prevents replay.
#   8. Expiry and parameter mismatch checks deny invalid grants.
#   9. Lab home and gate refuse enforcement.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

ACTION_GATE="$ROOT/bin/fm-action-gate.sh"
LABHOME="$ROOT/bin/fm-lab-home.sh"
FIXTURES_DIR="$ROOT/tests/fixtures/si-control-p4"

TMP=$(fm_test_tmproot fm-action-gate-test)
LAB="$TMP/labhome"
bash "$LABHOME" create "$LAB" >/dev/null 2>&1 || fail "fm-lab-home create failed"

BOOKING_FIXTURE="$FIXTURES_DIR/grant-booking.json"
CHARGING_FIXTURE="$FIXTURES_DIR/grant-charging.json"
DEPLOY_FIXTURE="$FIXTURES_DIR/grant-deploy.json"
STORE="$LAB/state/grants"
mkdir -p "$STORE"

# --- 1. Fixture Validation -------------------------------------------------

for f in "$BOOKING_FIXTURE" "$CHARGING_FIXTURE" "$DEPLOY_FIXTURE"; do
  [ -f "$f" ] || fail "fixture $f is missing"
  jq -e . "$f" >/dev/null 2>&1 || fail "fixture $f is not valid JSON"
done
pass "all Phase 4 synthetic grant fixtures exist and parse as valid JSON"

# --- 2. Mail Send Rules ----------------------------------------------------

# Mail send is hard-denied always
out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check mail_send recipient@example.com task-1 2>&1 || true)
assert_contains "$out" "DENY" "mail_send must be denied"
pass "mail_send is strictly DENIED"

out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check send recipient@example.com task-1 2>&1 || true)
assert_contains "$out" "DENY" "send must be denied"
pass "send is strictly DENIED"

# Draft is allowed
out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check mail_draft draft-box task-1 2>&1)
assert_contains "$out" "ALLOW" "mail_draft must be allowed"
pass "mail_draft is ALLOWED"

out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check draft draft-box task-1 2>&1)
assert_contains "$out" "ALLOW" "draft must be allowed"
pass "draft is ALLOWED"

# --- 3. Deny-by-Default / Review Without Grant ----------------------------

# Booking without grant routes to HUMAN_REVIEW
out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check booking cal-sched task-1 2>&1 || true)
assert_contains "$out" "HUMAN_REVIEW" "booking without grant must route to HUMAN_REVIEW"
pass "booking without grant routes to HUMAN_REVIEW"

# Charging without grant routes to HUMAN_REVIEW
out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check charging acct-stripe task-1 2>&1 || true)
assert_contains "$out" "HUMAN_REVIEW" "charging without grant must route to HUMAN_REVIEW"
pass "charging without grant routes to HUMAN_REVIEW"

# prod_deploy without grant routes to HUMAN_REVIEW
out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check prod_deploy srv-app task-1 2>&1 || true)
assert_contains "$out" "HUMAN_REVIEW" "prod_deploy without grant must route to HUMAN_REVIEW"
pass "prod_deploy without grant routes to HUMAN_REVIEW"

# Execution without grant fails
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" execute booking cal-sched task-1 "" echo "executed" >/dev/null 2>&1 && fail "execution without grant must fail"
pass "execution without grant is refused"

# --- 4. Valid Human Grants Allow Execution ---------------------------------

# Booking execution with valid grant
BOOKING_GRANT="$STORE/booking-grant.json"
cp "$BOOKING_FIXTURE" "$BOOKING_GRANT"
out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check booking cal-doctor-sched task-booking-001 "$BOOKING_GRANT")
assert_contains "$out" "ALLOW" "valid booking grant must ALLOW"
pass "valid booking grant returns ALLOW"

EXEC_OUT="$TMP/exec.out"
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" execute booking cal-doctor-sched task-booking-001 "$BOOKING_GRANT" sh -c "echo booking-ok > '$EXEC_OUT'" || fail "booking execution failed"
assert_contains "$(cat "$EXEC_OUT")" "booking-ok" "booking command should execute"
pass "valid booking grant executes command"

# Charging execution with valid grant
CHARGING_GRANT="$STORE/charging-grant.json"
cp "$CHARGING_FIXTURE" "$CHARGING_GRANT"
out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check charging acct-stripe-prod task-charge-001 "$CHARGING_GRANT")
assert_contains "$out" "ALLOW" "valid charging grant must ALLOW"
pass "valid charging grant returns ALLOW"

env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" execute charging acct-stripe-prod task-charge-001 "$CHARGING_GRANT" sh -c "echo charge-ok > '$EXEC_OUT'" || fail "charging execution failed"
assert_contains "$(cat "$EXEC_OUT")" "charge-ok" "charging command should execute"
pass "valid charging grant executes command"

# prod_deploy execution with valid grant
DEPLOY_GRANT="$STORE/deploy-grant.json"
cp "$DEPLOY_FIXTURE" "$DEPLOY_GRANT"
out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check prod_deploy srv-covenant-app task-deploy-001 "$DEPLOY_GRANT")
assert_contains "$out" "ALLOW" "valid prod_deploy grant must ALLOW"
pass "valid prod_deploy grant returns ALLOW"

env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" execute prod_deploy srv-covenant-app task-deploy-001 "$DEPLOY_GRANT" sh -c "echo deploy-ok > '$EXEC_OUT'" || fail "deploy execution failed"
assert_contains "$(cat "$EXEC_OUT")" "deploy-ok" "deploy command should execute"
pass "valid prod_deploy grant executes command"

# --- 5. Atomic One-Use Consumption & Replay Denial -------------------------

# The booking grant used above must now be consumed
used_ts=$(jq -r '.used_at // empty' "$BOOKING_GRANT")
[ -n "$used_ts" ] || fail "used_at must be stamped on consumed grant"
pass "atomic one-use execution stamps used_at timestamp"

# Immediate replay attempt on consumed booking grant must be DENIED
out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check booking cal-doctor-sched task-booking-001 "$BOOKING_GRANT" 2>&1 || true)
assert_contains "$out" "DENY" "replayed grant must be DENIED"
pass "replayed booking grant is DENIED"

# Execution with consumed grant must fail
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" execute booking cal-doctor-sched task-booking-001 "$BOOKING_GRANT" echo "fail" >/dev/null 2>&1 && fail "execution with consumed grant must fail"
pass "execution with consumed grant is refused"

# --- 6. Expiry and Mismatch Rules -----------------------------------------

# Expired grant
EXPIRED_GRANT="$STORE/expired-grant.json"
jq '.expires_at = "2020-01-01T00:00:00Z"' "$CHARGING_FIXTURE" > "$EXPIRED_GRANT"
out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check charging acct-stripe-prod task-charge-001 "$EXPIRED_GRANT" 2>&1 || true)
assert_contains "$out" "DENY" "expired grant must be DENIED"
pass "expired grant is DENIED"

# Action class mismatch
MISMATCH_GRANT="$STORE/mismatch-grant.json"
jq '.approval_reference = "captain-grant-mismatch"' "$CHARGING_FIXTURE" > "$MISMATCH_GRANT"
out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check booking acct-stripe-prod task-charge-001 "$MISMATCH_GRANT" 2>&1 || true)
assert_contains "$out" "DENY" "action class mismatch must be DENIED"
pass "action class mismatch is DENIED"

# Target mismatch
out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check charging wrong-target task-charge-001 "$MISMATCH_GRANT" 2>&1 || true)
assert_contains "$out" "DENY" "target mismatch must be DENIED"
pass "target mismatch is DENIED"

# Task ID mismatch
out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check charging acct-stripe-prod different-task "$MISMATCH_GRANT" 2>&1 || true)
assert_contains "$out" "DENY" "task ID mismatch must be DENIED"
pass "task identity mismatch is DENIED"

# Omitted request task cannot match a task-bound grant
out=$(env -u FM_TASK_ID FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check charging acct-stripe-prod "" "$MISMATCH_GRANT" 2>&1 || true)
assert_contains "$out" "DENY" "omitted request task must be DENIED"
pass "omitted request task is DENIED"

# Grant without a task binding matches no task
UNBOUND_GRANT="$STORE/unbound-grant.json"
jq '.task_id = "" | .approval_reference = "captain-grant-unbound"' "$CHARGING_FIXTURE" > "$UNBOUND_GRANT"
out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check charging acct-stripe-prod task-charge-001 "$UNBOUND_GRANT" 2>&1 || true)
assert_contains "$out" "DENY" "grant without task binding must be DENIED"
pass "grant without task binding is DENIED"

# Grant outside the grant store is DENIED even when well-formed
FORGED="$TMP/forged-grant.json"
jq '.approval_reference = "forged-ref"' "$DEPLOY_FIXTURE" > "$FORGED"
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" execute prod_deploy srv-covenant-app task-deploy-001 "$FORGED" sh -c "echo forged > '$TMP/forged.out'" >/dev/null 2>&1 && fail "grant outside store must be refused"
[ ! -e "$TMP/forged.out" ] || fail "forged grant command must not run"
pass "grant outside the grant store is refused"

# Copying a consumed grant and resetting used_at cannot replay its approval_reference
REPLAY_COPY="$STORE/replay-copy.json"
jq '.used_at = null' "$BOOKING_GRANT" > "$REPLAY_COPY"
out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check booking cal-doctor-sched task-booking-001 "$REPLAY_COPY" 2>&1 || true)
assert_contains "$out" "DENY" "copied consumed grant must be DENIED"
pass "copied consumed grant cannot replay its approval_reference"

# Malformed JSON grant
MALFORMED="$STORE/malformed.json"
echo "{bad:json" > "$MALFORMED"
out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check charging acct-stripe-prod task-charge-001 "$MALFORMED" 2>&1 || true)
assert_contains "$out" "DENY" "malformed JSON grant must be DENIED"
pass "malformed JSON grant is DENIED"

# --- 7. Runner Cannot Mint Grants -----------------------------------------

RUNNER_MINT="$STORE/runner-mint.json"
# An untrusted runner attempting to mint a grant must be refused
env FM_RUNNER_UNTRUSTED=1 bash "$ACTION_GATE" mint-grant "$RUNNER_MINT" booking cal-target task-1 "2030-01-01T00:00:00Z" "captain-grant" >/dev/null 2>&1 && fail "runner must not be able to mint grant"
pass "untrusted runner is refused from minting grant"

# An agent task without captain auth attempting to mint must be refused
env FM_TASK_ID="task-agent-01" FM_CAPTAIN_AUTH="" bash "$ACTION_GATE" mint-grant "$RUNNER_MINT" booking cal-target task-1 "2030-01-01T00:00:00Z" "captain-grant" >/dev/null 2>&1 && fail "agent task without captain auth must not mint grant"
pass "agent task without captain auth cannot mint grant"

# Minting with captain auth succeeds
CAPTAIN_MINT="$STORE/captain-mint.json"
env FM_HOME="$LAB" FM_CAPTAIN_AUTH=1 bash "$ACTION_GATE" mint-grant "$CAPTAIN_MINT" booking cal-target task-1 "2030-01-01T00:00:00Z" "captain-grant-valid" || fail "captain minting failed"
[ -f "$CAPTAIN_MINT" ] || fail "captain-mint.json missing"
pass "captain authority can mint valid grant"

env FM_HOME="$LAB" FM_CAPTAIN_AUTH=1 bash "$ACTION_GATE" mint-grant "$TMP/outside-mint.json" booking cal-target task-1 "2030-01-01T00:00:00Z" "captain-grant-outside" >/dev/null 2>&1 && fail "mint outside grant store must be refused"
env FM_HOME="$LAB" FM_CAPTAIN_AUTH=1 bash "$ACTION_GATE" mint-grant "$STORE/no-task.json" booking cal-target "" "2030-01-01T00:00:00Z" "captain-grant-notask" >/dev/null 2>&1 && fail "mint without task must be refused"
pass "mint refuses grants outside the store or without a task binding"

# --- 8. JEV Advisory Role: Cannot Grant Allow -----------------------------

# JEV claiming allow without captain approval is DENIED
JEV_ALLOW_GRANT="$STORE/jev-allow.json"
jq '.approval_reference = null | .jev_classification = {decision: "allow", confidence: 0.99}' "$BOOKING_FIXTURE" > "$JEV_ALLOW_GRANT"
out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check booking cal-doctor-sched task-booking-001 "$JEV_ALLOW_GRANT" 2>&1 || true)
assert_contains "$out" "DENY" "JEV claiming allow without captain approval must DENY"
pass "JEV self-grant without captain approval is DENIED"

# JEV flagging risky routes to HUMAN_REVIEW
JEV_RISKY_GRANT="$STORE/jev-risky.json"
jq '.approval_reference = null | .jev_classification = {risk_label: "risky", confidence: 0.95}' "$BOOKING_FIXTURE" > "$JEV_RISKY_GRANT"
out=$(env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check booking cal-doctor-sched task-booking-001 "$JEV_RISKY_GRANT" 2>&1 || true)
assert_contains "$out" "HUMAN_REVIEW" "JEV risk flag must route to HUMAN_REVIEW"
pass "JEV advisory risk flag routes to HUMAN_REVIEW"

# --- 9. Evidence Ledger Append-Only Integrity ------------------------------

LEDGER="$LAB/state/evidence/actions/action-ledger.jsonl"
[ -f "$LEDGER" ] || fail "action ledger missing at $LEDGER"
ledger_count=$(wc -l < "$LEDGER")
[ "$ledger_count" -gt 0 ] || fail "action ledger must contain records"
pass "action ledger contains recorded decisions ($ledger_count entries)"

# Verify ledger record schema
jq -e '
  .timestamp != null and
  .decision != null and
  .action_class != null and
  .target != null and
  .task_id != null and
  .reason != null
' "$LEDGER" >/dev/null 2>&1 || fail "ledger entries must conform to schema"
pass "action ledger entries conform to schema"

# --- 10. Concurrency: Exact One-Use Consumption ----------------------------

CONCURRENT_GRANT="$STORE/concurrent-grant.json"
jq '.approval_reference = "captain-grant-concurrent"' "$BOOKING_FIXTURE" > "$CONCURRENT_GRANT"

PIDS=()
for i in 1 2 3 4; do
  env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" execute booking cal-doctor-sched task-booking-001 "$CONCURRENT_GRANT" echo "ok-$i" >/dev/null 2>&1 &
  PIDS+=($!)
done

success_count=0
fail_count=0
for pid in "${PIDS[@]}"; do
  if wait "$pid"; then
    success_count=$((success_count + 1))
  else
    fail_count=$((fail_count + 1))
  fi
done

[ "$success_count" -eq 1 ] || fail "exactly one concurrent execution must succeed, got $success_count"
[ "$fail_count" -eq 3 ] || fail "three concurrent executions must be denied, got $fail_count"
pass "concurrent execute attempts consume one-time grant exactly once"

# --- 11. Draft Execution & Fail-Closed Ledger ------------------------------

DRAFT_DECOY="$TMP/draft-decoy.json"
echo '{"used_at":null}' > "$DRAFT_DECOY"
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" execute mail_draft draft-box task-1 "$DRAFT_DECOY" sh -c "echo draft-ok > '$EXEC_OUT'" >/dev/null || fail "draft execution failed"
assert_contains "$(cat "$EXEC_OUT")" "draft-ok" "draft command should execute"
[ "$(jq -r '.used_at' "$DRAFT_DECOY")" = "null" ] || fail "draft execution must not touch the passed file"
pass "draft executes without consuming any grant"

env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" execute mail_draft draft-box task-1 >/dev/null 2>&1 || fail "draft execute without grant or command must succeed without running action args"
pass "draft execute with omitted grant does not run action args as a command"

BROKEN="$TMP/broken-home"
mkdir -p "$BROKEN/state"
: > "$BROKEN/state/evidence"
out=$(env FM_HOME="$BROKEN" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" check draft draft-box task-1 2>&1 || true)
assert_contains "$out" "DENY" "unwritable ledger must DENY"
env FM_HOME="$BROKEN" FM_GATE_REFUSE_BYPASS=1 bash "$ACTION_GATE" execute draft draft-box task-1 "" sh -c "echo unrecorded > '$TMP/unrecorded.out'" >/dev/null 2>&1 && fail "execute with unwritable ledger must be refused"
[ ! -e "$TMP/unrecorded.out" ] || fail "unrecorded action must not run"
pass "unwritable evidence ledger fails closed"

# --- 12. Gate Refuse Contract Under NO_MISTAKES_GATE=1 --------------------

out=$(env NO_MISTAKES_GATE=1 FM_HOME="$TMP/unmarked" FM_GATE_REFUSE_BYPASS="" bash "$ACTION_GATE" check booking cal-sched task-1 2>&1 || true)
assert_contains "$out" "no-mistakes gate agent must not drive the fleet" "action gate must refuse under NO_MISTAKES_GATE=1"
pass "action gate refuses real fleet mutation under NO_MISTAKES_GATE=1"

out=$(env -u FM_CREW_STATE_META_OVERRIDE -u FM_CREW_STATE_STATUS_OVERRIDE NO_MISTAKES_GATE=1 FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS="" bash "$ACTION_GATE" check booking cal-target task-1 "$CAPTAIN_MINT" 2>&1 || true)
assert_contains "$out" "ALLOW" "marked lab home must be permitted for action gate"
pass "action gate permits marked disposable lab home"

echo "ok: all Phase 4 action gate tests passed completely"
