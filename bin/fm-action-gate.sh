#!/usr/bin/env bash
# fm-action-gate.sh - protected executor entrypoint for consequential actions.
#
# SI Control Phase 4: Actions Layer.
# Single decision point for mail_send, booking, charging, and prod_deploy.
#
# Usage:
#   fm-action-gate.sh check <action_class> <target> <task> [grant_file]
#   fm-action-gate.sh execute <action_class> <target> <task> <grant_file> [cmd...]
#     (draft classes carry no grant: pass "" as grant_file before cmd)
#   fm-action-gate.sh mint-grant <out_file> <action_class> <target> <task> <expires_at> <approval_ref>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-action-gate-lib.sh
. "$SCRIPT_DIR/fm-action-gate-lib.sh"

# Refuse gate agent lifecycle against real fleet
fm_refuse_if_gate_agent

cmd=${1:-}

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

    decision=$(fm_action_gate_check "$action_class" "$target" "$task_id" "$grant_file")
    status=$?
    if [ "$status" -ne 0 ] || [ "$decision" != "$FM_ACTION_ALLOW" ]; then
      echo "fm-action-gate: execution refused: decision was '$decision'" >&2
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
    if [ $# -gt 0 ]; then
      exec "$@"
    fi
    exit 0
    ;;
  mint-grant)
    shift
    out_file=${1:-}
    action_class=${2:-}
    target=${3:-}
    task_id=${4:-}
    expires_at=${5:-}
    approval_ref=${6:-}
    fm_action_gate_mint_grant "$out_file" "$action_class" "$target" "$task_id" "$expires_at" "$approval_ref"
    exit $?
    ;;
  *)
    echo "usage: fm-action-gate.sh check|execute|mint-grant <args...>" >&2
    exit 2
    ;;
esac
