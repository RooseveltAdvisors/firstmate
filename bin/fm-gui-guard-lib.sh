#!/usr/bin/env bash
# fm-gui-guard-lib.sh - GUI containment router guard library.
#
# SI Control Phase 3: Section 5 GUI Containment.
#
# Enforces account and session surface separation:
#   - AGT access uses dedicated automation accounts only.
#   - Personal browser profiles or captain logged-in sessions are strictly forbidden.
#   - Contexts not in the automation allowlist fail closed (REFUSE).
#   - Missing map entries, unverifiable spaces, or unknown aliases REFUSE.
#   - Refusal events are durably recorded in the evidence ledger.

FM_GUI_GUARD_ALLOW=0
FM_GUI_GUARD_REFUSE=1

fm_gui_guard_error() {
  echo "fm-gui-guard: $*" >&2
}

# Record GUI router decision / refusal to evidence store
fm_gui_guard_record_evidence() {
  local home=${FM_HOME:-.}
  local evidence_dir="$home/state/evidence/gui"
  local outcome=$1
  local reason=$2
  local context_alias=$3
  local host=$4
  local task_id=${FM_TASK_ID:-unknown}

  mkdir -p "$evidence_dir" 2>/dev/null || return 0
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
  local log_file="$evidence_dir/gui-router-ledger.jsonl"

  local entry
  if command -v jq >/dev/null 2>&1; then
    entry=$(jq -nc \
      --arg ts "$timestamp" \
      --arg outcome "$outcome" \
      --arg reason "$reason" \
      --arg alias "$context_alias" \
      --arg host "$host" \
      --arg task_id "$task_id" \
      '{timestamp: $ts, outcome: $outcome, reason: $reason, context_alias: $alias, host: $host, task_id: $task_id}')
  else
    entry="{\"timestamp\":\"$timestamp\",\"outcome\":\"$outcome\",\"reason\":\"$reason\",\"context_alias\":\"$context_alias\",\"host\":\"$host\",\"task_id\":\"$task_id\"}"
  fi

  printf '%s\n' "$entry" >> "$log_file" 2>/dev/null || true
}

# Validate a GUI context request against a containment map.
# Usage: fm_gui_guard_check_context <map_json_path> <requested_alias> <requested_host>
fm_gui_guard_check_context() {
  local map_path=${1:-}
  local requested_alias=${2:-}
  local requested_host=${3:-}

  if [ -z "$requested_alias" ] || [ -z "$requested_host" ]; then
    fm_gui_guard_error "REFUSE: missing alias or host"
    fm_gui_guard_record_evidence "REFUSE" "missing-parameters" "$requested_alias" "$requested_host"
    return "$FM_GUI_GUARD_REFUSE"
  fi

  if [ -z "$map_path" ] || [ ! -f "$map_path" ]; then
    fm_gui_guard_error "REFUSE: missing-containment-map (router map not found)"
    fm_gui_guard_record_evidence "REFUSE" "missing-containment-map" "$requested_alias" "$requested_host"
    return "$FM_GUI_GUARD_REFUSE"
  fi

  if ! command -v jq >/dev/null 2>&1; then
    fm_gui_guard_error "REFUSE: missing-jq (cannot parse containment map)"
    fm_gui_guard_record_evidence "REFUSE" "missing-jq" "$requested_alias" "$requested_host"
    return "$FM_GUI_GUARD_REFUSE"
  fi

  # 1. Host allowlist check
  local host_allowed
  host_allowed=$(jq --arg h "$requested_host" '.allowed_hosts // [] | index($h) != null' "$map_path" 2>/dev/null)
  if [ "$host_allowed" != "true" ]; then
    fm_gui_guard_error "REFUSE: host-not-allowlisted ('$requested_host' is not an approved automation host)"
    fm_gui_guard_record_evidence "REFUSE" "host-not-allowlisted" "$requested_alias" "$requested_host"
    return "$FM_GUI_GUARD_REFUSE"
  fi

  # 2. Explicitly blocked / personal context check
  local is_blocked
  is_blocked=$(jq -r --arg a "$requested_alias" '.blocked_contexts[$a] != null' "$map_path" 2>/dev/null)
  if [ "$is_blocked" = "true" ]; then
    local block_reason
    block_reason=$(jq -r --arg a "$requested_alias" '.blocked_contexts[$a].reason // "blocked context"' "$map_path" 2>/dev/null)
    fm_gui_guard_error "REFUSE: personal-or-blocked-context ('$requested_alias': $block_reason)"
    fm_gui_guard_record_evidence "REFUSE" "personal-or-blocked-context" "$requested_alias" "$requested_host"
    return "$FM_GUI_GUARD_REFUSE"
  fi

  # 3. Context entry lookup
  local ctx_obj
  ctx_obj=$(jq -r --arg a "$requested_alias" '.contexts[$a] // empty' "$map_path" 2>/dev/null)
  if [ -z "$ctx_obj" ]; then
    fm_gui_guard_error "REFUSE: unmapped-context-alias ('$requested_alias' not defined in automation map)"
    fm_gui_guard_record_evidence "REFUSE" "unmapped-context-alias" "$requested_alias" "$requested_host"
    return "$FM_GUI_GUARD_REFUSE"
  fi

  # 4. Automation account verification
  local acct_type ctx_host
  acct_type=$(jq -r --arg a "$requested_alias" '.contexts[$a].account_type // empty' "$map_path" 2>/dev/null)
  ctx_host=$(jq -r --arg a "$requested_alias" '.contexts[$a].host // empty' "$map_path" 2>/dev/null)

  if [ "$acct_type" != "automation" ]; then
    fm_gui_guard_error "REFUSE: non-automation-account (account type is '$acct_type', must be 'automation')"
    fm_gui_guard_record_evidence "REFUSE" "non-automation-account" "$requested_alias" "$requested_host"
    return "$FM_GUI_GUARD_REFUSE"
  fi

  if [ "$ctx_host" != "$requested_host" ]; then
    fm_gui_guard_error "REFUSE: host-context-mismatch (alias '$requested_alias' mapped to host '$ctx_host', not '$requested_host')"
    fm_gui_guard_record_evidence "REFUSE" "host-context-mismatch" "$requested_alias" "$requested_host"
    return "$FM_GUI_GUARD_REFUSE"
  fi

  fm_gui_guard_record_evidence "ALLOW" "verified-automation-context" "$requested_alias" "$requested_host"
  return "$FM_GUI_GUARD_ALLOW"
}
