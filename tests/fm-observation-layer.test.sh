#!/usr/bin/env bash
# fm-observation-layer.test.sh - Scope Area 1: Observation Layer tests.
#
# SI Control Phase 3:
#   1. Record schema conforms strictly to Section 2.3 (PHI-free by construction).
#   2. Local append-only spooling, rotation, and OTLP shipping.
#   3. Trace context propagation integration (W3C traceparent -> trace_id/span_id).
#   4. Failure rule: failed observation write never blocks or leaks content to general logs.
#   5. Protected store retention class (metadata_general_90d).
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

OBS_RECORD="$ROOT/bin/fm-observation-record.sh"
OBS_SHIPPER="$ROOT/bin/fm-observation-spool-shipper.sh"
TRACE_LIB="$ROOT/bin/fm-trace-context-lib.sh"
LABHOME="$ROOT/bin/fm-lab-home.sh"

TMP=$(fm_test_tmproot fm-observation-layer)

# Create a disposable lab home for observation state
LAB="$TMP/labhome"
bash "$LABHOME" create "$LAB" >/dev/null 2>&1 || fail "fm-lab-home create failed"

# Test 1: Record schema conformance & PHI-free enforcement
SPOOL_FILE="$LAB/state/observation/spool.jsonl"
rm -f "$SPOOL_FILE"

env FM_HOME="$LAB" FM_TASK_ID="task-obs-test-001" TRACEPARENT="00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" \
  bash "$OBS_RECORD" write anthropic claude-3-5-sonnet-20241022 850 120 45 ok >/dev/null 2>&1 || fail "fm-observation-record failed"

[ -f "$SPOOL_FILE" ] || fail "observation spool file was not created"
pass "observation metadata record successfully written to spool"

RECORD=$(tail -n 1 "$SPOOL_FILE")

# Validate required field groups
jq -e '
  .identity.task_id == "task-obs-test-001" and
  .identity.trace_id == "4bf92f3577b34da6a3ce929d0e0e4736" and
  .identity.span_id == "00f067aa0ba902b7" and
  .identity.runtime_identity.harness == "pi" and
  .call.provider == "anthropic" and
  .call.model == "claude-3-5-sonnet-20241022" and
  .call.duration_ms == 850 and
  .call.status == "ok" and
  .usage.input_tokens == 120 and
  .usage.output_tokens == 45 and
  .retention.retention_policy_class == "metadata_general_90d"
' <<< "$RECORD" >/dev/null 2>&1 || fail "recorded observation JSON schema mismatch"
pass "recorded observation JSON contains all required identity, call, usage, and retention fields"

# Strict assertion: NO sensitive forbidden content
if grep -i -E "prompt|completion|tool_arguments|file_contents|password|secret|bearer\s+|mrn|ssn|patient_id" <<< "$RECORD" >/dev/null 2>&1; then
  fail "observation record contains forbidden content keys"
fi
pass "observation record is strictly PHI-free and credential-free"

# Test 2: Trace context propagation integration
# When TRACEPARENT is absent, fallback trace_id/span_id are minted or zero-filled safely
env FM_HOME="$LAB" FM_TASK_ID="task-obs-test-002" TRACEPARENT="" \
  bash "$OBS_RECORD" write openai gpt-4o 400 50 20 ok >/dev/null 2>&1 || fail "fm-observation-record with empty TRACEPARENT failed"

RECORD2=$(tail -n 1 "$SPOOL_FILE")
jq -e '.identity.trace_id != null and .identity.span_id != null' <<< "$RECORD2" >/dev/null 2>&1 || fail "missing trace identity on unparented call"
pass "unparented call resolves safe trace identifiers"

# Test 3: Spool status and rotation
status_out=$(env FM_HOME="$LAB" bash "$OBS_SHIPPER" status)
if [ "${status_out#*records}" = "$status_out" ]; then
  fail "spool shipper status failed to report record count (output: $status_out)"
fi
pass "observation spool shipper accurately reports spool metrics"

# Test 4: Shipper failure rule (Section 2.6)
# When OTLP gateway is unreachable, shipping does NOT fail catastrophically or drop records silently
env FM_HOME="$LAB" OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:49999/v1/logs" \
  bash "$OBS_SHIPPER" ship >/dev/null 2>&1 || fail "shipper should exit 0 and retain records on endpoint failure"

# Verify batch file was retained in shipped directory for retry
BATCH_COUNT=$(find "$LAB/state/observation/shipped" -name "batch.*.jsonl" 2>/dev/null | wc -l)
[ "$BATCH_COUNT" -gt 0 ] || fail "failed shipment should retain batch for retry"
pass "shipper retains batch for retry when OTLP gateway is unreachable"

echo "ok: Scope Area 1 observation layer tests passed completely"
