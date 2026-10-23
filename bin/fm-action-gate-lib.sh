#!/usr/bin/env bash
# fm-action-gate-lib.sh - single protected executor decision gate for consequential actions.
#
# SI Control Phase 4: Actions Layer.
#
# Boundaries:
# Grants are only honored from the protected home-bound grant directory.
# Consumption markers live in $FM_HOME/state/action-consumed; they provide
# one-use behavior while operational state is intact, not protection against
# a hostile owner erasing that state.
# Grants are plain JSON in a root-owned, worker-read-only store.
# The administrator must protect the store and its ancestors against replacement.
# No signing key or brake state is required for admission.
# Runtime read-only checks are tripwires, not an OS ownership boundary.
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

fm_action_gate_home() {
  printf '%s' "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ACTION_GATE_ROOT}}"
}

# The protected grant store is home-bound, outside worker-owned FM_HOME.
# Keep the existing directory layout without requiring a brake.json beside it.
fm_action_gate_store() {
  local home digest
  home=$(cd "$(fm_action_gate_home)" && pwd -P) || return 1
  digest=$(printf '%s' "$home" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())') || return 1
  printf '%s/.action-control/%s/grants' "$FM_ACTION_GATE_ROOT" "$digest"
}

fm_action_gate_adapter_store() {
  local store
  store=$(fm_action_gate_store) || return 1
  printf '%s/adapters' "$(dirname "$store")"
}

# Only a root-owned file/directory without worker write access can supply a
# plain grant. Check real access too so a writable ACL cannot qualify.
fm_action_gate_protected() {
  local file=$1 metadata owner mode
  [ -e "$file" ] && [ ! -L "$file" ] || return 1
  metadata=$(stat -c '%u %a' "$file" 2>/dev/null || stat -f '%u %Lp' "$file") || return 1
  read -r owner mode <<< "$metadata"
  [ "$owner" = 0 ] && [ "$((8#$mode & 0022))" -eq 0 ] || return 1
  [ "$EUID" -eq 0 ] || [ ! -w "$file" ]
}

# Snapshot a protected plain JSON grant once; policy, payload and consumption
# use the same bytes. The protected parent prevents path replacement by workers.
fm_action_gate_load_grant() {
  local file=$1 document
  if [ "${FM_ACTION_GRANT_PATH:-}" = "$file" ] && [ -n "${FM_ACTION_GRANT_JSON:-}" ]; then
    return 0
  fi
  fm_action_gate_in_store "$file" && [ -f "$file" ] && fm_action_gate_protected "$file" || return 1
  document=$(cat "$file") || return 1
  printf '%s' "$document" | jq -e 'type=="object"' >/dev/null || return 1
  FM_ACTION_GRANT_PATH=$file
  FM_ACTION_GRANT_JSON=$document
}

fm_action_gate_grant_get() {
  printf '%s' "$FM_ACTION_GRANT_JSON" | jq -r "$1"
}

# Payload binding is checked before grant consumption. Consequential requests
# use HTTP or an explicitly registered protected deployment command adapter.
# Drafts use a built-in JSON draft renderer and never invoke caller programs.
fm_action_gate_payload() {
  local action=$1 target=$2 task=$3 grant=$4 prepared adapter_store
  shift 4
  case "$action" in
    mail_draft|draft)
      if [ "$#" -ne 2 ] || [ "$1" != draft-json ] ||
        ! printf '%s' "$2" | jq -e 'type=="object" and (keys-["body","subject","to"]|length)==0 and (.body|type)=="string" and (.subject|type)=="string" and (.to|type)=="string"' >/dev/null; then
          echo 'fm-action-gate: DENY: mail_draft accepts only draft-json with to, subject and body strings' >&2
          return 1
      fi
      ;;
    *)
      fm_action_gate_load_grant "$grant" || { echo 'fm-action-gate: DENY: unprotected or malformed grant payload' >&2; return 1; }
      adapter_store=$(fm_action_gate_adapter_store) || return 1
      prepared=$(printf '%s' "$FM_ACTION_GRANT_JSON" | python3 -I "$FM_ACTION_GATE_ROOT/bin/fm-action-request.py" match "$action" "$target" "$adapter_store" "$@") || return 1
      FM_ACTION_EXECUTION_PLAN=$prepared
      ;;
  esac
  # Keep bindings visible to evidence without logging command arguments.
  fm_action_gate_record_evidence "$FM_ACTION_ALLOW" "$action" "$target" "$task" "$grant" "payload-and-provenance-verified"
}

# Execute the validated in-memory plan. HTTP uses its exact approved snapshot;
# command adapters use a protected working directory and explicit environment.
fm_action_gate_execute_request() {
  printf '%s' "$FM_ACTION_EXECUTION_PLAN" | command -p env -i PATH="$PATH" python3 -I -c '
import http.client, json, os, ssl, sys
from urllib.parse import urlsplit
connection = None
try:
    plan = json.load(sys.stdin)
    if plan["kind"] == "protected-command":
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": plan["cwd"], "TZ": "UTC"}
        environment.update(plan["env"])
        os.chdir(plan["cwd"])
        os.execve(plan["argv"][0], plan["argv"], environment)
    if plan["kind"] != "http-json":
        raise ValueError("unknown approved adapter")
    request = plan["request"]
    url = urlsplit(request["url"])
    connection_type = http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection
    options = {"timeout": 30}
    if url.scheme == "https":
        options["context"] = ssl.create_default_context()
    connection = connection_type(url.hostname, url.port, **options)
    headers = dict(request["headers"])
    headers.update({"Content-Type": "application/json", "X-Account-ID": request["account_id"], "X-Credential-ID": request["credential_id"]})
    body = json.dumps(request["body"], sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8")
    path = (url.path or "/") + (("?" + url.query) if url.query else "")
    connection.request(request["method"], path, body=body, headers=headers)
    response = connection.getresponse()
    if not 200 <= response.status < 300:
        print("fm-action-gate: DENY: approved endpoint returned HTTP " + str(response.status) + "; redirects and fallback refuse", file=sys.stderr)
        sys.exit(1)
    print("ok: approved HTTP action completed, status=" + str(response.status))
except (OSError, ValueError, http.client.HTTPException) as error:
    print("fm-action-gate: DENY: approved adapter request failed (" + type(error).__name__ + ")", file=sys.stderr)
    sys.exit(1)
finally:
    if connection is not None:
        connection.close()
'
}

# Usage: fm_action_gate_in_store <file> - true when file sits directly in the grant store
fm_action_gate_in_store() {
  local f=$1 store
  [ -n "$f" ] && [ ! -L "$f" ] || return 1
  store=$(fm_action_gate_store) || return 1
  # Require the direct absolute spelling, so a worker-owned alias directory
  # cannot be switched between the protection check and the snapshot read.
  [ "$f" = "$store/${f##*/}" ] || return 1
  fm_action_gate_protected "$store" &&
    fm_action_gate_protected "$(dirname "$store")" &&
    fm_action_gate_protected "$(dirname "$(dirname "$store")")"
}

# approval_reference doubles as the consumption key, so it must be a safe name
fm_action_gate_valid_ref() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9_:\-]+$ ]]
}

# Append an action decision to the evidence ledger.
# Usage: fm_action_gate_record_evidence <decision> <action_class> <target> <task_id> <grant_ref> <reason>
fm_action_gate_record_evidence() {
  local decision=$1
  local action_class=$2
  local target=$3
  local task_id=${4:-${FM_TASK_ID:-unknown}}
  local grant_ref=${5:-none}
  local reason=$6

  local evidence_dir
  evidence_dir="$(fm_action_gate_home)/state/evidence/actions"
  mkdir -p "$evidence_dir" 2>/dev/null || return 1

  local timestamp
  timestamp=$(fm_action_gate_iso_now)
  local log_file="$evidence_dir/action-ledger.jsonl"

  local entry
  entry=$(jq -nc \
    --arg ts "$timestamp" \
    --arg dec "$decision" \
    --arg cls "$action_class" \
    --arg tgt "$target" \
    --arg task "$task_id" \
    --arg gr "$grant_ref" \
    --arg rsn "$reason" \
    '{timestamp: $ts, decision: $dec, action_class: $cls, target: $tgt, task_id: $task, grant_ref: $gr, reason: $rsn}') || return 1

  # This writer appends; OS ownership determines protection against tampering.
  printf '%s\n' "$entry" >> "$log_file" 2>/dev/null
}

# ALLOW only when the decision is durably recorded
# Usage: fm_action_gate_allow <action_class> <target> <task_id> <grant_ref> <reason>
fm_action_gate_allow() {
  if ! fm_action_gate_record_evidence "$FM_ACTION_ALLOW" "$@"; then
    echo "fm-action-gate: DENY: evidence ledger unwritable; refusing to allow unrecorded action" >&2
    echo "$FM_ACTION_DENY"
    return 1
  fi
  echo "$FM_ACTION_ALLOW"
}

# Mint a protected plain grant. Root provisions .action-control/<home>/grants
# (0755, root-owned) before minting. The executor never provisions it for a worker.
# Usage: fm_action_gate_mint_grant <out_file> <action_class> <target> <task_id> <expires_at> <approval_ref> <request_json_file>
fm_action_gate_mint_grant() {
  local out_file=$1 action_class=$2 target=$3 task_id=$4 expires_at=$5 approval_ref=$6
  local request_file=${7:-} tmp approved
  if [ "$EUID" -ne 0 ] || [ -n "${FM_RUNNER_UNTRUSTED:-}" ]; then
    echo 'fm-action-gate: DENY: only the administrator can mint grants' >&2
    return 1
  fi
  if ! fm_action_gate_valid_ref "$approval_ref" || ! fm_action_gate_valid_ref "$task_id"; then
    echo 'fm-action-gate: DENY: grant requires valid approval and task identifiers' >&2
    return 1
  fi
  case "$action_class" in booking|charging|prod_deploy|deploy) ;;
    *) echo 'fm-action-gate: DENY: unsupported grant action class' >&2; return 1 ;;
  esac
  if ! [ -f "$request_file" ]; then
    echo 'fm-action-gate: DENY: mint requires bound request JSON' >&2
    return 1
  fi
  approved=$(python3 -I "$FM_ACTION_GATE_ROOT/bin/fm-action-request.py" mint "$action_class" "$target" "$(fm_action_gate_adapter_store)" < "$request_file") || return 1
  if ! fm_action_gate_in_store "$out_file"; then
    echo 'fm-action-gate: DENY: grant requires a protected store' >&2
    return 1
  fi
  [ ! -e "$out_file" ] && [ ! -L "$out_file" ] || {
    echo 'fm-action-gate: DENY: refusing to overwrite existing grant' >&2
    return 1
  }
  tmp=$(mktemp "$(fm_action_gate_store)/.mint.XXXXXX") || return 1
  if ! jq -nc --arg cls "$action_class" --arg tgt "$target" --arg task "$task_id" \
    --arg exp "$expires_at" --arg app "$approval_ref" --argjson approved "$approved" \
    '{schema:"fm-action-grant.v2",action_class:$cls,target:$tgt,task_id:$task,expires_at:$exp,approval_reference:$app,used_at:null} + $approved' > "$tmp" ||
    ! chmod 444 "$tmp" || ! ln "$tmp" "$out_file"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}

# Atomically consume a one-time grant in the operational home, keyed by its
# approval_reference. The protected plain grant itself is immutable.
# Usage: fm_action_gate_consume <grant_file>
fm_action_gate_consume() {
  local grant_file=$1
  if ! fm_action_gate_in_store "$grant_file" || [ ! -f "$grant_file" ]; then
    return 1
  fi

  local ref consumed_dir
  fm_action_gate_load_grant "$grant_file" || return 1
  ref=$(fm_action_gate_grant_get '.approval_reference // empty') || return 1
  fm_action_gate_valid_ref "$ref" || return 1
  consumed_dir="$(fm_action_gate_home)/state/action-consumed"
  mkdir -p "$consumed_dir" 2>/dev/null || return 1
  if ! mkdir "$consumed_dir/$ref" 2>/dev/null; then
    # Already consumed
    return 1
  fi

  # Stamp use in the marker, preserving the protected plain grant.
  local ts
  ts=$(fm_action_gate_iso_now)
  if ! printf '%s\n' "$ts" > "$consumed_dir/$ref/used_at"; then
    echo 'fm-action-gate: DENY: could not stamp consumed grant' >&2
    return 1
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

  if ! command -v jq >/dev/null 2>&1; then
    echo "fm-action-gate: DENY: missing jq parser" >&2
    echo "$FM_ACTION_DENY"
    return 1
  fi

  if [ -z "$action_class" ] || [ -z "$target" ]; then
    echo "fm-action-gate: usage error: action_class and target are required" >&2
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "${action_class:-unknown}" "${target:-unknown}" "$task_id" "none" "missing-required-parameters"
    echo "$FM_ACTION_DENY"
    return 1
  fi

  # 1. Hard deny: mail_send / send is strictly forbidden. Draft allowed.
  case "$action_class" in
    mail_draft | draft)
      fm_action_gate_allow "$action_class" "$target" "$task_id" "draft-policy" "drafting permitted"
      return
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
  if ! fm_action_gate_in_store "$grant_file"; then
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$grant_file" "grant-outside-store"
    echo "fm-action-gate: DENY: grant must come from the grant store $(fm_action_gate_store)" >&2
    echo "$FM_ACTION_DENY"
    return 1
  fi

  if ! fm_action_gate_load_grant "$grant_file"; then
    echo 'fm-action-gate: DENY: grant is unprotected or malformed JSON' >&2
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$grant_file" "invalid-plain-grant"
    echo "$FM_ACTION_DENY"
    return 1
  fi

  local g_class g_target g_task g_expires g_approval g_used g_jev_risk g_jev_grant
  g_class=$(fm_action_gate_grant_get '.action_class // empty')
  g_target=$(fm_action_gate_grant_get '.target // empty')
  g_task=$(fm_action_gate_grant_get '.task_id // empty')
  g_expires=$(fm_action_gate_grant_get '.expires_at // empty')
  g_approval=$(fm_action_gate_grant_get '.approval_reference // empty')
  g_used=$(fm_action_gate_grant_get '.used_at // empty')
  g_jev_risk=$(fm_action_gate_grant_get '.jev_classification.risk_label // empty')
  g_jev_grant=$(fm_action_gate_grant_get '.jev_classification.decision // empty')

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
  if ! fm_action_gate_valid_ref "$g_approval"; then
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

  # Task match: grant is bound to exactly one task
  if [ -z "$g_task" ] || [ "$g_task" != "$task_id" ]; then
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

  # One-use check: no used_at field or operational consumption marker.
  if [ -n "$g_used" ] && [ "$g_used" != "null" ]; then
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$g_approval" "grant-already-used"
    echo "fm-action-gate: DENY: grant was already used" >&2
    echo "$FM_ACTION_DENY"
    return 1
  fi

  if [ -d "$(fm_action_gate_home)/state/action-consumed/$g_approval" ]; then
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$g_approval" "grant-consumed-directory-exists"
    echo "fm-action-gate: DENY: grant already consumed" >&2
    echo "$FM_ACTION_DENY"
    return 1
  fi

  # Approval binds typed content as well as the label/task. Reject legacy or
  # incomplete records even for a check that does not execute an action.
  if ! printf '%s' "$FM_ACTION_GRANT_JSON" | python3 -I "$FM_ACTION_GATE_ROOT/bin/fm-action-request.py" check "$action_class" "$target" "$(fm_action_gate_adapter_store)" >/dev/null; then
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$g_approval" "request-binding-invalid"
    echo "$FM_ACTION_DENY"
    return 1
  fi

  # All checks passed
  fm_action_gate_allow "$action_class" "$target" "$task_id" "$g_approval" "grant verified"
}
