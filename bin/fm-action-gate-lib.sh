#!/usr/bin/env bash
# fm-action-gate-lib.sh - single protected executor decision gate for consequential actions.
#
# SI Control Phase 4: Actions Layer.
#
# Boundaries:
# The grant store permissions are the trust boundary: someone who can write
# grants or the executor already has that authority (same honesty rule as the
# bin-parent boundary). Note it as a decision, not an oversight.
#
# Decision values:
#   ALLOW        - Action permitted and gate passes.
#   DENY         - Action prohibited and gate stops execution.
#   HUMAN_REVIEW - Consequential action with no matching grant, routed to captain.
#
# Exit codes:
#   0 - ALLOW
#   1 - DENY
#   2 - HUMAN_REVIEW

FM_ACTION_ALLOW="ALLOW"
FM_ACTION_DENY="DENY"
FM_ACTION_REVIEW="HUMAN_REVIEW"

FM_ACTION_GATE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_action_gate_iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ"
}

# Record action decision to append-only evidence ledger
# Usage: fm_action_gate_record_evidence <decision> <action_class> <target> <task_id> <grant_ref> <reason>
fm_action_gate_record_evidence() {
  local decision=$1
  local action_class=$2
  local target=$3
  local task_id=${4:-${FM_TASK_ID:-unknown}}
  local grant_ref=${5:-none}
  local reason=$6

  local home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ACTION_GATE_ROOT}}
  local evidence_dir="$home/state/evidence/actions"
  mkdir -p "$evidence_dir" 2>/dev/null || return 0

  local timestamp
  timestamp=$(fm_action_gate_iso_now)
  local log_file="$evidence_dir/action-ledger.jsonl"

  local entry
  if command -v jq >/dev/null 2>&1; then
    entry=$(jq -nc \
      --arg ts "$timestamp" \
      --arg dec "$decision" \
      --arg cls "$action_class" \
      --arg tgt "$target" \
      --arg task "$task_id" \
      --arg gr "$grant_ref" \
      --arg rsn "$reason" \
      '{timestamp: $ts, decision: $dec, action_class: $cls, target: $tgt, task_id: $task, grant_ref: $gr, reason: $rsn}')
  else
    entry="{\"timestamp\":\"$timestamp\",\"decision\":\"$decision\",\"action_class\":\"$action_class\",\"target\":\"$target\",\"task_id\":\"$task_id\",\"grant_ref\":\"$grant_ref\",\"reason\":\"$reason\"}"
  fi

  # Ledger is append-only
  printf '%s\n' "$entry" >> "$log_file" 2>/dev/null || true
}

# Mint a human grant record (only callable with captain authority, never by runner alone)
# Usage: fm_action_gate_mint_grant <out_file> <action_class> <target> <task_id> <expires_at> <approval_ref>
fm_action_gate_mint_grant() {
  local out_file=$1
  local action_class=$2
  local target=$3
  local task_id=$4
  local expires_at=$5
  local approval_ref=$6

  # Runner cannot create its own grants
  if [ -n "${FM_RUNNER_UNTRUSTED:-}" ] || { [ -n "${FM_TASK_ID:-}" ] && [ -z "${FM_CAPTAIN_AUTH:-}" ]; }; then
    echo "fm-action-gate: refusal: runner cannot create or mint its own grants" >&2
    return 1
  fi

  if [ -z "$approval_ref" ] || [ "$approval_ref" = "null" ]; then
    echo "fm-action-gate: refusal: grant requires explicit captain approval_reference" >&2
    return 1
  fi

  mkdir -p "$(dirname "$out_file")" 2>/dev/null || true

  if command -v jq >/dev/null 2>&1; then
    jq -nc \
      --arg cls "$action_class" \
      --arg tgt "$target" \
      --arg task "$task_id" \
      --arg exp "$expires_at" \
      --arg app "$approval_ref" \
      '{action_class: $cls, target: $tgt, task_id: $task, expires_at: $exp, approval_reference: $app, used_at: null}' > "$out_file"
  else
    printf '{"action_class":"%s","target":"%s","task_id":"%s","expires_at":"%s","approval_reference":"%s","used_at":null}\n' \
      "$action_class" "$target" "$task_id" "$expires_at" "$approval_ref" > "$out_file"
  fi
}

# Atomically consume a one-time grant
# Usage: fm_action_gate_consume <grant_file>
fm_action_gate_consume() {
  local grant_file=$1
  if [ -z "$grant_file" ] || [ ! -f "$grant_file" ]; then
    return 1
  fi

  local lock_dir="$grant_file.consumed"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    # Already consumed
    return 1
  fi

  # Stamp used_at timestamp atomically inside the grant file
  local ts
  ts=$(fm_action_gate_iso_now)
  if command -v jq >/dev/null 2>&1; then
    local tmp="$grant_file.tmp.$$"
    if jq --arg ts "$ts" '.used_at = $ts' "$grant_file" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$grant_file"
    else
      rm -f "$tmp"
    fi
  fi
  return 0
}

# Single decision point for consequential actions
# Usage: fm_action_gate_check <action_class> <target> <task> [grant_file]
# Prints ALLOW | DENY | HUMAN_REVIEW to stdout.
# Exits 0 for ALLOW, 1 for DENY, 2 for HUMAN_REVIEW.
fm_action_gate_check() {
  local action_class=${1:-}
  local target=${2:-}
  local task_id=${3:-${FM_TASK_ID:-}}
  local grant_file=${4:-}

  if [ -z "$action_class" ] || [ -z "$target" ]; then
    echo "fm-action-gate: usage error: action_class and target are required" >&2
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "${action_class:-unknown}" "${target:-unknown}" "$task_id" "none" "missing-required-parameters"
    echo "$FM_ACTION_DENY"
    return 1
  fi

  # 1. Hard deny: mail_send / send is strictly forbidden. Draft allowed.
  case "$action_class" in
    mail_draft | draft)
      fm_action_gate_record_evidence "$FM_ACTION_ALLOW" "$action_class" "$target" "$task_id" "draft-policy" "drafting permitted"
      echo "$FM_ACTION_ALLOW"
      return 0
      ;;
    mail_send | send)
      fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "none" "mail_send strictly prohibited"
      echo "fm-action-gate: DENY: real mail send is strictly prohibited; only drafts are permitted" >&2
      echo "$FM_ACTION_DENY"
      return 1
      ;;
    booking | charging | prod_deploy | deploy)
      # Handled below under grant evaluation
      ;;
    *)
      fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "none" "unknown action class"
      echo "fm-action-gate: DENY: unknown action class '$action_class'" >&2
      echo "$FM_ACTION_DENY"
      return 1
      ;;
  esac

  # Normalize prod_deploy synonym
  if [ "$action_class" = "deploy" ]; then
    action_class="prod_deploy"
  fi

  # 2. Consequential action check: booking, charging, prod_deploy
  # If no grant file provided or file does not exist -> HUMAN_REVIEW
  if [ -z "$grant_file" ] || [ ! -f "$grant_file" ]; then
    fm_action_gate_record_evidence "$FM_ACTION_REVIEW" "$action_class" "$target" "$task_id" "none" "missing grant routes to captain review"
    echo "fm-action-gate: HUMAN_REVIEW: action requires captain grant; routing to review" >&2
    echo "$FM_ACTION_REVIEW"
    return 2
  fi

  # 3. Grant verification
  if ! command -v jq >/dev/null 2>&1; then
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$grant_file" "missing jq for verification"
    echo "fm-action-gate: DENY: missing jq parser" >&2
    echo "$FM_ACTION_DENY"
    return 1
  fi

  if ! jq -e . "$grant_file" >/dev/null 2>&1; then
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$grant_file" "malformed JSON grant"
    echo "fm-action-gate: DENY: malformed JSON grant" >&2
    echo "$FM_ACTION_DENY"
    return 1
  fi

  local g_class g_target g_task g_expires g_approval g_used g_jev_risk g_jev_grant
  g_class=$(jq -r '.action_class // empty' "$grant_file")
  g_target=$(jq -r '.target // empty' "$grant_file")
  g_task=$(jq -r '.task_id // empty' "$grant_file")
  g_expires=$(jq -r '.expires_at // empty' "$grant_file")
  g_approval=$(jq -r '.approval_reference // empty' "$grant_file")
  g_used=$(jq -r '.used_at // empty' "$grant_file")
  g_jev_risk=$(jq -r '.jev_classification.risk_label // empty' "$grant_file")
  g_jev_grant=$(jq -r '.jev_classification.decision // empty' "$grant_file")

  # Normalize synonym in grant
  if [ "$g_class" = "deploy" ]; then
    g_class="prod_deploy"
  fi

  # Boundary: JEV alone cannot grant access
  if [ -n "$g_jev_grant" ] && [ "$g_jev_grant" = "allow" ] && { [ -z "$g_approval" ] || [ "$g_approval" = "null" ]; }; then
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$grant_file" "jev-cannot-grant"
    echo "fm-action-gate: DENY: JEV is advisory only and cannot grant access without captain approval" >&2
    echo "$FM_ACTION_DENY"
    return 1
  fi

  # JEV advisory risk flag routes to HUMAN_REVIEW
  if [ "$g_jev_risk" = "risky" ] && { [ -z "$g_approval" ] || [ "$g_approval" = "null" ]; }; then
    fm_action_gate_record_evidence "$FM_ACTION_REVIEW" "$action_class" "$target" "$task_id" "$grant_file" "jev-flagged-risky"
    echo "fm-action-gate: HUMAN_REVIEW: JEV flagged action as risky; routing to captain review" >&2
    echo "$FM_ACTION_REVIEW"
    return 2
  fi

  # Human approval reference is required
  if [ -z "$g_approval" ] || [ "$g_approval" = "null" ]; then
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$grant_file" "missing-approval-reference"
    echo "fm-action-gate: DENY: grant lacks human approval_reference" >&2
    echo "$FM_ACTION_DENY"
    return 1
  fi

  # Class match
  if [ "$g_class" != "$action_class" ]; then
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$g_approval" "action-class-mismatch"
    echo "fm-action-gate: DENY: action class mismatch (requested '$action_class', grant has '$g_class')" >&2
    echo "$FM_ACTION_DENY"
    return 1
  fi

  # Target match
  if [ "$g_target" != "$target" ]; then
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$g_approval" "target-mismatch"
    echo "fm-action-gate: DENY: target mismatch (requested '$target', grant has '$g_target')" >&2
    echo "$FM_ACTION_DENY"
    return 1
  fi

  # Task match (if task_id requested)
  if [ -n "$task_id" ] && [ -n "$g_task" ] && [ "$g_task" != "$task_id" ]; then
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$g_approval" "task-id-mismatch"
    echo "fm-action-gate: DENY: task identity mismatch (requested '$task_id', grant has '$g_task')" >&2
    echo "$FM_ACTION_DENY"
    return 1
  fi

  # Expiry check
  if [ -z "$g_expires" ] || [ "$g_expires" = "null" ]; then
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$g_approval" "missing-expiry"
    echo "fm-action-gate: DENY: grant missing expiry" >&2
    echo "$FM_ACTION_DENY"
    return 1
  fi

  local now_ts exp_epoch now_epoch
  now_ts=$(fm_action_gate_iso_now)
  exp_epoch=$(date -u -d "$g_expires" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$g_expires" +%s 2>/dev/null || true)
  now_epoch=$(date -u -d "$now_ts" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$now_ts" +%s 2>/dev/null || true)

  if [ -z "$exp_epoch" ] || [ -z "$now_epoch" ]; then
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$g_approval" "unparseable-expiry"
    echo "fm-action-gate: DENY: unparseable expiry timestamp" >&2
    echo "$FM_ACTION_DENY"
    return 1
  fi

  if [ "$now_epoch" -ge "$exp_epoch" ]; then
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$g_approval" "grant-expired"
    echo "fm-action-gate: DENY: grant has expired" >&2
    echo "$FM_ACTION_DENY"
    return 1
  fi

  # One-use check: must not have used_at timestamp or .consumed mutex directory
  if [ -n "$g_used" ] && [ "$g_used" != "null" ]; then
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$g_approval" "grant-already-used"
    echo "fm-action-gate: DENY: grant was already used" >&2
    echo "$FM_ACTION_DENY"
    return 1
  fi

  if [ -d "$grant_file.consumed" ]; then
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$g_approval" "grant-consumed-directory-exists"
    echo "fm-action-gate: DENY: grant already consumed" >&2
    echo "$FM_ACTION_DENY"
    return 1
  fi

  # All checks passed
  fm_action_gate_record_evidence "$FM_ACTION_ALLOW" "$action_class" "$target" "$task_id" "$g_approval" "grant verified"
  echo "$FM_ACTION_ALLOW"
  return 0
}
