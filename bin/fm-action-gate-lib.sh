#!/usr/bin/env bash
# fm-action-gate-lib.sh - single protected executor decision gate for consequential actions.
#
# SI Control Phase 4: Actions Layer.
#
# Boundaries:
# Grants are only honored from the protected home-bound control directory.
# Consumption markers live in $FM_HOME/state/action-consumed; they provide
# one-use behavior while operational state is intact, not protection against
# a hostile owner erasing that state.
# Grants and brake state are signed with an administrator's private key.
# bin/fm-action-authority.pem pins the public key in the installed Git baseline.
# The private key is never installed in the worker's accessible filesystem.
# The administrator must also protect the control directory and its ancestors
# against replacement/replay. Runtime read-only checks are tripwires, not an OS
# ownership boundary. Missing control provisioning fails closed.
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

fm_action_gate_store() {
  local control
  control=$(fm_action_gate_control_file) || return 1
  printf '%s/grants' "$(dirname "$control")"
}

# Sign canonical JSON without its signature field, then verify the result
# against the installed public key before publishing. Keys are operator inputs;
# no environment flag can substitute for possession of the signing key.
fm_action_gate_sign() {
  local file=$1 key=$2 signature tmp
  if [ ! -r "$key" ] || [ ! -f "$FM_ACTION_GATE_ROOT/bin/fm-action-authority.pem" ]; then
    echo 'fm-action-gate: DENY: administrator signing key or pinned public key missing' >&2
    return 1
  fi
  signature=$(jq -cS 'del(.signature)' "$file" |
    openssl dgst -sha256 -sign "$key" | openssl base64 -A) || return 1
  tmp=$(mktemp) || return 1
  if ! jq --arg sig "$signature" '.signature=$sig' "$file" > "$tmp" ||
    ! fm_action_gate_verify "$tmp"; then
    rm -f "$tmp"
    echo "fm-action-gate: DENY: signing key does not match installed authority" >&2
    return 1
  fi
  mv "$tmp" "$file"
}

fm_action_gate_verify() {
  local file=$1 document
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  document=$(cat "$file") || return 1
  fm_action_gate_verify_json "$document"
}

fm_action_gate_verify_json() {
  local document=$1 signature
  [ -f "$FM_ACTION_GATE_ROOT/bin/fm-action-authority.pem" ] || return 1
  signature=$(printf '%s' "$document" | jq -er '.signature | select(type=="string" and length>0)') || return 1
  # Verification intermediates stay in pipes, never worker-writable temp files.
  printf '%s' "$document" | jq -cS 'del(.signature)' |
    openssl dgst -sha256 -verify "$FM_ACTION_GATE_ROOT/bin/fm-action-authority.pem" \
      -signature <(printf '%s' "$signature" | openssl base64 -d -A) >/dev/null 2>&1
}

fm_action_gate_load_grant() {
  local file=$1 document
  if [ "${FM_ACTION_GRANT_PATH:-}" = "$file" ] && [ -n "${FM_ACTION_GRANT_JSON:-}" ]; then
    return 0
  fi
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  document=$(cat "$file") || return 1
  fm_action_gate_verify_json "$document" || return 1
  printf '%s' "$document" | jq -e '.schema=="fm-action-grant.v1"' >/dev/null || return 1
  FM_ACTION_GRANT_PATH=$file
  FM_ACTION_GRANT_JSON=$document
}

fm_action_gate_grant_get() {
  printf '%s' "$FM_ACTION_GRANT_JSON" | jq -r "$1"
}

fm_action_gate_control_file() {
  local home digest
  home=$(cd "$(fm_action_gate_home)" && pwd -P) || return 1
  digest=$(printf '%s' "$home" | openssl dgst -sha256) || return 1
  digest=${digest##* }
  # Kept with the protected code, outside the worker's mutable FM_HOME.
  printf '%s/.action-control/%s/brake.json' "$FM_ACTION_GATE_ROOT" "$digest"
}

# Every successful admission reads a signed, home-bound brake state. A missing,
# writable, malformed, replaced or unsigned record never means "brake clear".
fm_action_gate_control_read() {
  local file home document
  file=$(fm_action_gate_control_file) || return 1
  home=$(cd "$(fm_action_gate_home)" && pwd -P) || return 1
  document=$(cat "$file") || { echo 'fm-action-gate: DENY: brake state missing' >&2; return 1; }
  if ! fm_action_gate_readonly "$file" || ! fm_action_gate_readonly "$(dirname "$file")" ||
    ! fm_action_gate_verify_json "$document" ||
    ! printf '%s' "$document" | jq -e --arg home "$home" '.schema=="fm-action-control.v1" and .home==$home and (.active|type)=="boolean" and (.revoked|type)=="array" and (.reconciliation|type)=="array"' >/dev/null; then
    echo "fm-action-gate: DENY: brake state missing, writable or unauthenticated; operator provisioning required" >&2
    return 1
  fi
  printf '%s\n' "$document"
}

# Root's administrator interface necessarily has owner write authority. It
# still requires root ownership and no group/other write permissions. Worker
# invocations use effective access checks, including ACLs.
fm_action_gate_readonly() {
  local file=$1 metadata owner mode
  [ -e "$file" ] && [ ! -L "$file" ] || return 1
  if [ "$EUID" -eq 0 ]; then
    metadata=$(stat -c '%u %a' "$file" 2>/dev/null || stat -f '%u %Lp' "$file") || return 1
    read -r owner mode <<< "$metadata"
    [ "$owner" = 0 ] && [ "$((8#$mode & 0022))" -eq 0 ]
  else
    [ ! -w "$file" ]
  fi
}

fm_action_gate_brake_clear() {
  local state
  state=$(fm_action_gate_control_read) || return 1
  if [ "$(printf '%s' "$state" | jq -r .active)" != false ]; then
    echo "fm-action-gate: DENY: human brake is active" >&2
    return 1
  fi
  printf '%s\n' "$state"
}

# init-control <private_key> <approval_ref>, or brake set|clear <private_key>
# <approval_ref>. Called under the executor's admission lock. Publish only a
# verified signature and keep outstanding grants revoked after brake clear.
fm_action_gate_brake() {
  local mode=$1 key=$2 ref=$3 file dir home tmp state grants='[]' active=false
  if ! fm_action_gate_valid_ref "$ref"; then
    echo 'fm-action-gate: DENY: control requires a valid approval reference' >&2
    return 1
  fi
  file=$(fm_action_gate_control_file) || return 1
  dir=$(dirname "$file")
  home=$(cd "$(fm_action_gate_home)" && pwd -P) || return 1
  tmp=$(mktemp) || return 1
  if [ "$mode" = init ]; then
    [ ! -e "$dir" ] || { rm -f "$tmp"; echo 'fm-action-gate: DENY: control already exists' >&2; return 1; }
    state=$(jq -nc --arg home "$home" '{schema:"fm-action-control.v1",home:$home,active:false,revoked:[],reconciliation:[]}')
  else
    state=$(fm_action_gate_control_read) || { rm -f "$tmp"; return 1; }
  fi
  if [ "$mode" = set ]; then
    active=true
    local grant record
    for grant in "$(fm_action_gate_store)"/*.json; do
      [ -f "$grant" ] || continue
      # Invalid/unsigned queue entries cannot be executed, but still appear in
      # reconciliation so the operator sees everything that was queued.
      record=$(jq -nc --arg file "$grant" --arg ref "$(jq -r '.approval_reference // "invalid"' "$grant" 2>/dev/null || echo invalid)" \
        '{grant:$file,approval_reference:$ref,status:"revoked-by-brake"}') || { rm -f "$tmp"; return 1; }
      grants=$(printf '%s' "$grants" | jq --argjson row "$record" '.+[$row]')
    done
  fi
  printf '%s' "$state" | jq --argjson active "$active" --arg ref "$ref" \
    --arg ts "$(fm_action_gate_iso_now)" --arg mode "$mode" --argjson grants "$grants" \
    '.active=$active | .approval_reference=$ref | .updated_at=$ts |
     .revoked=((.revoked+[$grants[].approval_reference])|unique) |
     .reconciliation += [{timestamp:$ts,operation:$mode,approval_reference:$ref,queued:$grants}] |
     del(.signature)' > "$tmp" || { rm -f "$tmp"; return 1; }
  fm_action_gate_sign "$tmp" "$key" || { rm -f "$tmp"; return 1; }
  # The signed reconciliation is the administrative evidence record. Never
  # write privileged admin output through the worker-owned operational tree.
  if [ "$mode" = init ]; then
    mkdir -p "$(dirname "$dir")" || { rm -f "$tmp"; return 1; }
    chmod 755 "$(dirname "$dir")" || { rm -f "$tmp"; return 1; }
    mkdir "$dir" || { rm -f "$tmp"; return 1; }
    if ! (umask 022; : > "$dir/admission.lock") || ! chmod 444 "$dir/admission.lock"; then
      rm -f "$tmp"
      return 1
    fi
    if ! mkdir "$dir/grants" || ! chmod 755 "$dir/grants"; then
      rm -f "$tmp"
      return 1
    fi
  else
    chmod u+w "$dir" || { rm -f "$tmp"; return 1; }
  fi
  if ! chmod 444 "$tmp" || ! mv -f "$tmp" "$file"; then
    chmod a-w "$dir"
    rm -f "$tmp"
    return 1
  fi
  chmod a-w "$dir" || return 1
  echo "ok: human brake $mode; signed reconciliation recorded"
}

# Payload binding is checked before grant consumption. Consequential commands
# must match the exact signed argv; provenance is part of the same signature.
# Drafts use a built-in JSON draft renderer and never invoke caller programs.
fm_action_gate_payload() {
  local action=$1 target=$2 task=$3 grant=$4 argv request origin kind
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
      fm_action_gate_load_grant "$grant" || { echo 'fm-action-gate: DENY: unsigned or altered grant payload' >&2; return 1; }
      request=$(fm_action_gate_grant_get '.request') || return 1
      kind=$(printf '%s' "$request" | jq -r '.provenance.kind // empty')
      origin=$(printf '%s' "$request" | jq -r '.provenance.origin_action_class // empty')
      [ "$origin" != deploy ] || origin=prod_deploy
      [ "$action" != deploy ] || action=prod_deploy
      case "$kind" in trusted|untrusted-forwarded) ;; *) echo 'fm-action-gate: DENY: missing bound provenance' >&2; return 1 ;; esac
      if [ "$origin" != "$action" ]; then
        echo "fm-action-gate: DENY: provenance origin '$origin' cannot be relabeled '$action'" >&2
        return 1
      fi
      argv=$(jq -nc --args '$ARGS.positional' -- "$@") || return 1
      if [ "$#" -eq 0 ] || ! printf '%s' "$request" | jq -e --argjson argv "$argv" '.argv==$argv' >/dev/null; then
        echo 'fm-action-gate: DENY: command differs from signed approved payload' >&2
        return 1
      fi
      ;;
  esac
  # Keep bindings visible to evidence without logging command arguments.
  fm_action_gate_record_evidence "$FM_ACTION_ALLOW" "$action" "$target" "$task" "$grant" "payload-and-provenance-verified"
}

# Usage: fm_action_gate_in_store <file> - true when file sits directly in the grant store
fm_action_gate_in_store() {
  local f=$1 store dir
  [ -n "$f" ] && [ ! -L "$f" ] || return 1
  store=$(cd "$(fm_action_gate_store)" 2>/dev/null && pwd -P) || return 1
  dir=$(cd "$(dirname "$f")" 2>/dev/null && pwd -P) || return 1
  [ "$dir" = "$store" ]
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

# Mint a human grant record (only callable with captain authority, never by runner alone)
# Usage: fm_action_gate_mint_grant <out_file> <action_class> <target> <task_id> <expires_at> <approval_ref> <request_json_file> <private_key>
fm_action_gate_mint_grant() {
  local out_file=$1
  local action_class=$2
  local target=$3
  local task_id=$4
  local expires_at=$5
  local approval_ref=$6
  local request_file=${7:-} key=${8:-} tmp

  fm_action_gate_brake_clear >/dev/null || return 1

  # Runner cannot create its own grants
  if [ -n "${FM_RUNNER_UNTRUSTED:-}" ]; then
    echo "fm-action-gate: refusal: runner cannot create or mint its own grants" >&2
    return 1
  fi

  if [ ! -f "$request_file" ] || [ ! -r "$key" ]; then
    echo 'fm-action-gate: DENY: mint requires bound request JSON and administrator signing key' >&2
    return 1
  fi
  if ! jq -e '.provenance.kind|strings' "$request_file" >/dev/null; then
    echo 'fm-action-gate: DENY: request requires provenance' >&2
    return 1
  fi

  if ! fm_action_gate_valid_ref "$approval_ref"; then
    echo "fm-action-gate: refusal: grant requires explicit captain approval_reference ([A-Za-z0-9_:-])" >&2
    return 1
  fi

  if [ -z "$task_id" ]; then
    echo "fm-action-gate: refusal: grant requires a task_id binding" >&2
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "fm-action-gate: refusal: missing jq parser" >&2
    return 1
  fi

  if ! fm_action_gate_in_store "$out_file"; then
    echo "fm-action-gate: refusal: grant must be minted into the grant store $(fm_action_gate_store)" >&2
    return 1
  fi

  [ ! -e "$out_file" ] && [ ! -L "$out_file" ] || {
    echo 'fm-action-gate: DENY: refusing to overwrite existing grant' >&2
    return 1
  }
  tmp=$(mktemp "$(fm_action_gate_store)/.mint.XXXXXX") || return 1
  if ! jq -nc \
    --arg cls "$action_class" \
    --arg tgt "$target" \
    --arg task "$task_id" \
    --arg exp "$expires_at" \
    --arg app "$approval_ref" --slurpfile request "$request_file" \
    '{schema:"fm-action-grant.v1",action_class: $cls, target: $tgt, task_id: $task, expires_at: $exp, approval_reference: $app, used_at: null,request:$request[0]}' > "$tmp" ||
    ! fm_action_gate_sign "$tmp" "$key"; then
    rm -f "$tmp"
    return 1
  fi
  if ! chmod 444 "$tmp" || ! ln "$tmp" "$out_file"; then rm -f "$tmp"; return 1; fi
  rm -f "$tmp"
}

# Atomically consume a one-time grant in the operational home, keyed by its
# signed approval_reference. The protected signed grant itself is immutable.
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

  # Stamp use in the marker, preserving the administrator's grant signature.
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
  local grant_file=${4:-} control

  if ! control=$(fm_action_gate_brake_clear); then
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$grant_file" "human-brake-or-invalid-control"
    echo "$FM_ACTION_DENY"
    return 1
  fi

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

  if ! jq -e . "$grant_file" >/dev/null 2>&1; then
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$grant_file" "malformed JSON grant"
    echo "fm-action-gate: DENY: malformed JSON grant" >&2
    echo "$FM_ACTION_DENY"
    return 1
  fi

  if ! fm_action_gate_load_grant "$grant_file"; then
    echo 'fm-action-gate: DENY: unsigned or altered grant' >&2
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$grant_file" "invalid-grant-signature"
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

  if ! printf '%s' "$control" | jq -e --arg ref "$g_approval" '.revoked | index($ref)==null' >/dev/null; then
    fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$g_approval" "grant-revoked-by-brake"
    echo 'fm-action-gate: DENY: grant revoked by human brake' >&2
    echo "$FM_ACTION_DENY"
    return 1
  fi

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

  # All checks passed
  fm_action_gate_allow "$action_class" "$target" "$task_id" "$g_approval" "grant verified"
}
