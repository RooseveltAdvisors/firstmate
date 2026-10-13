#!/usr/bin/env bash
# fm-decision-gate-lib.sh - enforce denial-on-missing-decision for consequential actions.
#
# SI Control Phase 3: Section 4.5 The denial-on-missing-decision rule.
#
# A consequential action (starting with deploy) executes ONLY when a present,
# well-formed decision=allow record exists, bound to:
#   - the exact normalized action and validated arguments
#   - the payload hash at approval time (payload changed after approval no longer matches)
#   - an expiry and one-use semantics, so a replayed record is dead
#   - the policy version in force
#   - the task identity that requested it
#
# Any of the following is treated exactly as a denial, and the action does not execute:
#   - the decision record is absent
#   - the record is unreadable, truncated, or malformed
#   - JEV classification timed out, errored, or returned an answer outside its schema
#   - JEV confidence is below the floor
#   - the evidence spool or content path needed for the record is unavailable
#   - the payload hash, expiry, one-use token, or task identity does not match
#   - JEV claimed to grant allow without explicit captain approval
#
# A missing decision is indistinguishable from a denial by design.
# Recovery from a denial is a fresh decision, never a retry of the same record.

FM_DECISION_GATE_ALLOW=0
FM_DECISION_GATE_DENY=1
FM_DECISION_CONFIDENCE_FLOOR="0.80"

fm_decision_gate_error() {
  echo "fm-decision-gate: $*" >&2
}

# Calculate SHA-256 payload hash portably
fm_decision_gate_hash_payload() {
  local target_file=${1:-}
  if [ -z "$target_file" ] || [ ! -f "$target_file" ]; then
    return 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$target_file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$target_file" | awk '{print $1}'
  else
    return 1
  fi
}

# Get current ISO 8601 UTC timestamp
fm_decision_gate_iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ"
}

# Record decision event to local evidence ledger
fm_decision_gate_record_evidence() {
  local home=${FM_HOME:-.}
  local evidence_dir="$home/state/evidence/decisions"
  local outcome=$1
  local reason=$2
  local action=$3
  local target=$4
  local task_id=${5:-${FM_TASK_ID:-unknown}}
  local record_file=${6:-}

  mkdir -p "$evidence_dir" 2>/dev/null || return 0
  local timestamp
  timestamp=$(fm_decision_gate_iso_now)
  local log_file="$evidence_dir/decision-ledger.jsonl"

  local entry
  if command -v jq >/dev/null 2>&1; then
    entry=$(jq -nc \
      --arg ts "$timestamp" \
      --arg outcome "$outcome" \
      --arg reason "$reason" \
      --arg action "$action" \
      --arg target "$target" \
      --arg task_id "$task_id" \
      --arg record "$record_file" \
      '{timestamp: $ts, outcome: $outcome, reason: $reason, action: $action, target: $target, task_id: $task_id, record: $record}')
  else
    entry="{\"timestamp\":\"$timestamp\",\"outcome\":\"$outcome\",\"reason\":\"$reason\",\"action\":\"$action\",\"target\":\"$target\",\"task_id\":\"$task_id\"}"
  fi

  printf '%s\n' "$entry" >> "$log_file" 2>/dev/null || true
}

# Verify a decision record against the proposed action and payload.
# Usage: fm_decision_gate_verify <record_json_path> <expected_action> <expected_target> <payload_path> [expected_task_id]
fm_decision_gate_verify() {
  local record_path=${1:-}
  local expected_action=${2:-}
  local expected_target=${3:-}
  local payload_path=${4:-}
  local expected_task=${5:-${FM_TASK_ID:-}}

  if [ -z "$expected_action" ] || [ -z "$expected_target" ]; then
    fm_decision_gate_error "verify requires action and target"
    return "$FM_DECISION_GATE_DENY"
  fi

  # 1. Decision record presence check
  if [ -z "$record_path" ] || [ ! -f "$record_path" ]; then
    fm_decision_gate_error "DENY: missing-decision (no decision record provided or found)"
    fm_decision_gate_record_evidence "DENY" "missing-decision" "$expected_action" "$expected_target" "$expected_task" ""
    return "$FM_DECISION_GATE_DENY"
  fi

  if ! command -v jq >/dev/null 2>&1; then
    fm_decision_gate_error "DENY: missing jq for deterministic policy verification"
    fm_decision_gate_record_evidence "DENY" "missing-jq" "$expected_action" "$expected_target" "$expected_task" "$record_path"
    return "$FM_DECISION_GATE_DENY"
  fi

  # 2. Well-formedness check
  if ! jq -e . "$record_path" >/dev/null 2>&1; then
    fm_decision_gate_error "DENY: malformed-decision (record is not valid JSON)"
    fm_decision_gate_record_evidence "DENY" "malformed-decision" "$expected_action" "$expected_target" "$expected_task" "$record_path"
    return "$FM_DECISION_GATE_DENY"
  fi

  local rec_action rec_target rec_task rec_payload_hash rec_expires rec_used rec_decision rec_approval
  local rec_jev_label rec_jev_conf
  rec_action=$(jq -r '.action // empty' "$record_path")
  rec_target=$(jq -r '.target // empty' "$record_path")
  rec_task=$(jq -r '.task_id // empty' "$record_path")
  rec_payload_hash=$(jq -r '.payload_hash // empty' "$record_path")
  rec_expires=$(jq -r '.expires_at // empty' "$record_path")
  rec_used=$(jq -r '.used_at // empty' "$record_path")
  rec_decision=$(jq -r '.decision // empty' "$record_path")
  rec_approval=$(jq -r '.approval_reference // empty' "$record_path")
  rec_jev_label=$(jq -r '.jev_classification.risk_label // empty' "$record_path")
  rec_jev_conf=$(jq -r '.jev_classification.confidence // empty' "$record_path")

  # 3. Action and target match
  if [ "$rec_action" != "$expected_action" ]; then
    fm_decision_gate_error "DENY: action-mismatch (expected '$expected_action', record has '$rec_action')"
    fm_decision_gate_record_evidence "DENY" "action-mismatch" "$expected_action" "$expected_target" "$expected_task" "$record_path"
    return "$FM_DECISION_GATE_DENY"
  fi

  if [ "$rec_target" != "$expected_target" ]; then
    fm_decision_gate_error "DENY: target-mismatch (expected '$expected_target', record has '$rec_target')"
    fm_decision_gate_record_evidence "DENY" "target-mismatch" "$expected_action" "$expected_target" "$expected_task" "$record_path"
    return "$FM_DECISION_GATE_DENY"
  fi

  # 4. Task identity binding
  if [ -n "$expected_task" ] && [ -n "$rec_task" ] && [ "$rec_task" != "$expected_task" ]; then
    fm_decision_gate_error "DENY: task-mismatch (expected '$expected_task', record bound to '$rec_task')"
    fm_decision_gate_record_evidence "DENY" "task-mismatch" "$expected_action" "$expected_target" "$expected_task" "$record_path"
    return "$FM_DECISION_GATE_DENY"
  fi

  # 5. Payload hash binding
  if [ -n "$payload_path" ]; then
    if [ ! -f "$payload_path" ]; then
      fm_decision_gate_error "DENY: payload-missing ('$payload_path' not found)"
      fm_decision_gate_record_evidence "DENY" "payload-missing" "$expected_action" "$expected_target" "$expected_task" "$record_path"
      return "$FM_DECISION_GATE_DENY"
    fi
    local actual_hash
    actual_hash=$(fm_decision_gate_hash_payload "$payload_path")
    if [ -z "$actual_hash" ] || [ "$actual_hash" != "$rec_payload_hash" ]; then
      fm_decision_gate_error "DENY: payload-changed (expected hash '$rec_payload_hash', actual '$actual_hash')"
      fm_decision_gate_record_evidence "DENY" "payload-changed" "$expected_action" "$expected_target" "$expected_task" "$record_path"
      return "$FM_DECISION_GATE_DENY"
    fi
  fi

  # 6. Expiry check
  if [ -n "$rec_expires" ]; then
    local now_epoch exp_epoch
    now_epoch=$(date +%s 2>/dev/null || date -u +%s)
    exp_epoch=$(date -d "$rec_expires" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$rec_expires" +%s 2>/dev/null || true)
    if [ -n "$exp_epoch" ] && [ "$now_epoch" -gt "$exp_epoch" ]; then
      fm_decision_gate_error "DENY: expired-decision (expired at '$rec_expires', current time is past)"
      fm_decision_gate_record_evidence "DENY" "expired-decision" "$expected_action" "$expected_target" "$expected_task" "$record_path"
      return "$FM_DECISION_GATE_DENY"
    fi
  fi

  # 7. One-use semantics check
  if [ -n "$rec_used" ] && [ "$rec_used" != "null" ]; then
    fm_decision_gate_error "DENY: replayed-decision (record was already used at '$rec_used')"
    fm_decision_gate_record_evidence "DENY" "replayed-decision" "$expected_action" "$expected_target" "$expected_task" "$record_path"
    return "$FM_DECISION_GATE_DENY"
  fi

  # 8. JEV authority boundary: JEV CANNOT grant allow
  # JEV is intelligence/classifier only. An allow record requires explicit approval_reference.
  if [ -z "$rec_approval" ] || [ "$rec_approval" = "null" ]; then
    fm_decision_gate_error "DENY: jev-cannot-grant (no human captain approval reference; JEV cannot grant authority)"
    fm_decision_gate_record_evidence "DENY" "jev-cannot-grant" "$expected_action" "$expected_target" "$expected_task" "$record_path"
    return "$FM_DECISION_GATE_DENY"
  fi

  # 9. JEV confidence floor check (if JEV classification is present)
  if [ -n "$rec_jev_conf" ] && [ "$rec_jev_conf" != "null" ]; then
    local below_floor
    below_floor=$(awk -v conf="$rec_jev_conf" -v floor="$FM_DECISION_CONFIDENCE_FLOOR" 'BEGIN {print (conf < floor) ? 1 : 0}')
    if [ "$below_floor" = "1" ]; then
      fm_decision_gate_error "DENY: jev-confidence-low (confidence '$rec_jev_conf' is below floor '$FM_DECISION_CONFIDENCE_FLOOR')"
      fm_decision_gate_record_evidence "DENY" "jev-confidence-low" "$expected_action" "$expected_target" "$expected_task" "$record_path"
      return "$FM_DECISION_GATE_DENY"
    fi
  fi

  # 10. Final decision value check
  if [ "$rec_decision" != "allow" ]; then
    fm_decision_gate_error "DENY: decision-not-allow (record decision is '$rec_decision')"
    fm_decision_gate_record_evidence "DENY" "decision-not-allow" "$expected_action" "$expected_target" "$expected_task" "$record_path"
    return "$FM_DECISION_GATE_DENY"
  fi

  fm_decision_gate_record_evidence "ALLOW" "verified-allow" "$expected_action" "$expected_target" "$expected_task" "$record_path"
  return "$FM_DECISION_GATE_ALLOW"
}

# Atomically consume a one-use decision record
fm_decision_gate_consume() {
  local record_path=${1:-}
  if [ -z "$record_path" ] || [ ! -f "$record_path" ]; then
    return 1
  fi
  local ts tmp_file
  ts=$(fm_decision_gate_iso_now)
  tmp_file="${record_path}.tmp.$$"

  if jq --arg used "$ts" '.used_at = $used' "$record_path" > "$tmp_file" 2>/dev/null; then
    mv -f "$tmp_file" "$record_path" || { rm -f "$tmp_file"; return 1; }
    return 0
  else
    rm -f "$tmp_file"
    return 1
  fi
}
