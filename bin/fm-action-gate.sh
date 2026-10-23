#!/usr/bin/env bash
# fm-action-gate.sh - protected executor entrypoint for consequential actions.
#
# SI Control Phase 4: Actions Layer.
# Single decision point for mail_send, booking, charging, and prod_deploy.
#
# Usage:
#   fm-action-gate.sh check <action_class> <target> <task> [grant_file]
#   fm-action-gate.sh execute <action_class> <target> <task> <grant_file> [cmd...]
#     drafts: pass "" as grant, then draft-json '{"to":"...","subject":"...","body":"..."}'
#     consequential argv: http-json '<JSON object>', exactly as approved.
#   fm-action-gate.sh grant-store
#     Prints the home-bound grant store; root provisions that directory and its
#     two parents as root-owned 0755 beneath the protected checkout.
#   fm-action-gate.sh mint-grant <out_file> <action_class> <target> <task> <expires_at> <approval_ref> <request_json_file>
#     Administrator only; creates plain root-owned JSON (0444) in that store.
#     request: {"provenance":{"kind":"trusted|untrusted-forwarded","origin_action_class":"booking"},"argv":["http-json","<HTTP JSON>"]}
#     HTTP JSON: {"url":"https://...","method":"POST|PUT|PATCH|DELETE","account_id":"...","credential_id":"...","headers":{"Authorization":"..."},"body":{...}}
#     HTTP is accepted only for literal loopback test targets. Redirects refuse.
#     request_sha256 binds provenance, exact argv, URL, account, credential,
#     headers and body; payload_sha256 binds the canonical UTF-8 body bytes.
#     Legacy grants and arbitrary external commands refuse.
# No keypair, authority.pem or brake.json is required. Python 3 and jq are required.
# Root must protect the enforcement, Git baseline, grant store and ancestor paths
# against worker replacement. Worker-created or worker-writable grants deny.
# Internal tools use the system path. A read-only, Git-pinned bin/runtime-bin
# can supply missing platform dependencies; its tools and linked libraries must
# be administrator-controlled too. Caller PATH and exported functions are not
# an authority source. Invoke with a trusted Bash interpreter and clean startup
# environment; a shell startup hook runs before a shell script can check itself.
#
# Deployment: all enforcement files below must be read-only to the
# operating principal and match this checkout's HEAD. This runtime tripwire
# does not protect itself or HEAD from an owner who can replace them. An
# administrator must protect the installed files, baseline and parent paths;
# a writable development checkout deliberately refuses every action.
set -uo pipefail

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)"

# Clear imported command functions before using runtime tools.
builtin unset -f git jq python3 stat cat dirname mktemp chmod mkdir mv ln rm date sed printf read exec pwd cd command 2>/dev/null || true
# Verify before sourcing either library. Ignore caller Git-location overrides
# and replacement objects: the baseline belongs to this physical checkout.
fm_action_gate_integrity() {
  local root file expected actual admin=false owner mode metadata node
  local files=(fm-action-gate.sh fm-action-gate-lib.sh fm-action-request.py fm-gate-refuse-lib.sh)
  if [ -e "$SCRIPT_DIR/runtime-bin" ]; then
    files+=(runtime-bin)
    for node in "$SCRIPT_DIR/runtime-bin"/*; do
      [ -e "$node" ] || continue
      files+=("runtime-bin/${node##*/}")
    done
  fi
  # A root administrator can provision/control the installation, but only
  # root-owned files without group/other write permission qualify. The worker
  # path always checks actual writability, including ACLs.
  if [ "$EUID" -eq 0 ]; then
    case "${1:-}" in mint-grant|grant-store|-h|--help) admin=true ;; esac
  fi
  root=$(cd "$SCRIPT_DIR/.." && pwd -P) || return 1
  for file in "${files[@]}"; do
    if { [ ! -f "$SCRIPT_DIR/$file" ] && [ "$file" != runtime-bin ]; } || [ -L "$SCRIPT_DIR/$file" ]; then
      echo "fm-action-gate: DENY: enforcement tamper check: missing, symlinked or writable enforcement: $file" >&2
      return 1
    fi
    if [ "$admin" = true ]; then
      metadata=$(stat -c '%u %a' "$SCRIPT_DIR/$file" 2>/dev/null || stat -f '%u %Lp' "$SCRIPT_DIR/$file") || return 1
      read -r owner mode <<< "$metadata"
      if [ "$owner" != 0 ] || [ "$((8#$mode & 0022))" -ne 0 ]; then
        echo "fm-action-gate: DENY: enforcement tamper check: unsafe administrator installation: $file" >&2
        return 1
      fi
    elif [ -w "$SCRIPT_DIR/$file" ]; then
      echo "fm-action-gate: DENY: enforcement tamper check: writable enforcement: $file" >&2
      return 1
    fi
    [ "$file" != runtime-bin ] || continue
    expected=$(
      unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
      command -p git --no-replace-objects -c safe.directory="$root" -C "$root" rev-parse --verify "HEAD:bin/$file"
    ) || {
      echo "fm-action-gate: DENY: enforcement tamper check: missing committed baseline: $file" >&2
      return 1
    }
    actual=$(
      unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
      command -p git --no-replace-objects -c safe.directory="$root" -C "$root" hash-object --no-filters "$SCRIPT_DIR/$file"
    ) || return 1
    if [ "$expected" != "$actual" ]; then
      echo "fm-action-gate: DENY: enforcement tamper check: content differs from committed baseline: $file" >&2
      return 1
    fi
  done
}

if ! fm_action_gate_integrity "${1:-}"; then
  echo DENY
  exit 1
fi
if [ -d "$SCRIPT_DIR/runtime-bin" ]; then
  PATH="$PATH:$SCRIPT_DIR/runtime-bin"
fi
for dependency in git jq python3; do
  if ! command -v "$dependency" >/dev/null; then
    echo "fm-action-gate: DENY: missing trusted runtime dependency: $dependency" >&2
    exit 1
  fi
done
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-action-gate-lib.sh
. "$SCRIPT_DIR/fm-action-gate-lib.sh"

# Refuse gate agent lifecycle against real fleet
fm_refuse_if_gate_agent

cmd=${1:-}
# Never accept a caller-supplied cache of verified data.
FM_ACTION_GRANT_PATH=''
FM_ACTION_GRANT_JSON=''
FM_ACTION_HTTP_REQUEST=''
case "$cmd" in
  -h|--help)
    sed -n '2,/^set /{ /^set /d; s/^# \{0,1\}//; p; }' "$0"
    exit 0
    ;;
esac

case "$cmd" in
  check)
    shift
    action_class=${1:-}
    target=${2:-}
    task_id=${3:-${FM_TASK_ID:-}}
    grant_file=${4:-}
    fm_action_gate_check "$action_class" "$target" "$task_id" "$grant_file"
    exit $?
    ;;
  execute)
    shift
    action_class=${1:-}
    target=${2:-}
    task_id=${3:-${FM_TASK_ID:-}}
    grant_file=${4:-}
    if [ $# -ge 4 ]; then shift 4; else shift $#; fi

    # Load one protected plain JSON snapshot for policy and payload checks.
    case "$action_class" in
      mail_draft|draft|mail_send|send) ;;
      *)
        if [ -f "$grant_file" ] && ! fm_action_gate_load_grant "$grant_file"; then
          fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$grant_file" "invalid-plain-grant"
          echo 'fm-action-gate: DENY: grant is unprotected or malformed JSON' >&2
          exit 1
        fi
        ;;
    esac

    decision=$(fm_action_gate_check "$action_class" "$target" "$task_id" "$grant_file")
    status=$?
    if [ "$status" -ne 0 ] || [ "$decision" != "$FM_ACTION_ALLOW" ]; then
      echo "fm-action-gate: execution refused: decision was '$decision'" >&2
      exit 1
    fi

    if ! fm_action_gate_payload "$action_class" "$target" "$task_id" "$grant_file" "$@"; then
      fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$grant_file" "payload-or-provenance-refused"
      exit 1
    fi

    # Atomically consume one-time grant (drafts carry no grant)
    case "$action_class" in
      mail_draft | draft) ;;
      *)
        if ! fm_action_gate_consume "$grant_file"; then
          fm_action_gate_record_evidence "$FM_ACTION_DENY" "$action_class" "$target" "$task_id" "$grant_file" "grant-consumption-failed"
          echo "fm-action-gate: execution refused: failed to consume one-time grant" >&2
          exit 1
        fi
        ;;
    esac

    echo "ok: action gate passed, executing $action_class on $target"
    case "$action_class" in
      mail_draft|draft)
        printf '%s' "$2" | jq --arg target "$target" --arg task "$task_id" '{operation:"mail_draft",target:$target,task_id:$task,draft:.}'
        ;;
      *) fm_action_gate_http_execute ;;
    esac
    exit $?
    ;;
  mint-grant)
    shift
    out_file=${1:-}
    action_class=${2:-}
    target=${3:-}
    task_id=${4:-}
    expires_at=${5:-}
    approval_ref=${6:-}
    fm_action_gate_mint_grant "$out_file" "$action_class" "$target" "$task_id" "$expires_at" "$approval_ref" "${7:-}"
    exit $?
    ;;
  grant-store)
    fm_action_gate_store || exit 1
    printf '\n'
    ;;
  *)
    echo "usage: fm-action-gate.sh check|execute|mint-grant|grant-store <args...>" >&2
    exit 2
    ;;
esac
