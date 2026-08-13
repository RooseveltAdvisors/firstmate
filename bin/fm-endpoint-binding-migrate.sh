#!/usr/bin/env bash
# Evidence-bound migration for legacy task metadata without endpoint_task_id.
# Usage: fm-endpoint-binding-migrate.sh
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
FM_ROOT_OVERRIDE=$(printenv FM_ROOT_OVERRIDE 2>/dev/null || true)
FM_HOME=$(printenv FM_HOME 2>/dev/null || true)
if [ -n "$FM_ROOT_OVERRIDE" ]; then
  FM_ROOT=$FM_ROOT_OVERRIDE
else
  FM_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
fi
if [ -z "$FM_HOME" ]; then
  FM_HOME=$FM_ROOT
fi
STATE=$(printenv FM_STATE_OVERRIDE 2>/dev/null || true)
if [ -z "$STATE" ]; then
  STATE=$FM_HOME/state
fi

if [ "$#" -ne 0 ]; then
  echo "ENDPOINT_BINDING_MIGRATION: invalid argument" >&2
  exit 2
fi

. "$SCRIPT_DIR/fm-session-lock-lib.sh"
. "$SCRIPT_DIR/fm-wake-lib.sh"
. "$SCRIPT_DIR/fm-backend.sh"

[ -d "$STATE" ] && [ ! -L "$STATE" ] || {
  echo "ENDPOINT_BINDING_MIGRATION: state directory is unavailable; migration did not run" >&2
  exit 1
}

require_session_lock() {
  fm_session_lock_owned_by_self "$STATE" || {
    echo "ENDPOINT_BINDING_MIGRATION: session lock is not owned by this session; migration did not run" >&2
    return 1
  }
}

valid_task_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

regular_file() {
  [ -f "$1" ] && [ ! -L "$1" ]
}

reason_one_line() {
  printf '%s' "$1" | tr '\n' ' '
}

record_outcome() {
  printf '%s\n' "$1"
  OUTCOME_COUNT=$((OUTCOME_COUNT + 1))
}

record_endpoint_state_refusal() {
  local id=$1 backend=$2 state=$3
  case "$state" in
    dead|missing) record_outcome "task $id: skipped - dead endpoint" ;;
    ambiguous) record_outcome "task $id: skipped - ambiguous live endpoint identity" ;;
    unreadable) record_outcome "task $id: skipped - endpoint identity is unreadable" ;;
    unverified) record_outcome "task $id: skipped - backend '$backend' has no verified endpoint identity" ;;
    *) record_outcome "task $id: skipped - endpoint identity returned unexpected state '$state'" ;;
  esac
}

FM_ENDPOINT_VERIFIED_WORKTREE=
verify_live_task_worktree() {
  local meta=$1 id=$2 backend=$3 target=$4 recorded live recorded_real live_real exact_target state
  FM_ENDPOINT_VERIFIED_WORKTREE=
  recorded=$(fm_backend_meta_exact_value "$meta" worktree) || {
    record_outcome "task $id: skipped - recorded task worktree identity is unreadable"
    return 1
  }
  case "$backend" in
    tmux)
      target_session=$(printf '%s' "$target" | cut -d: -f1)
      target_window=$(printf '%s' "$target" | cut -d: -f2-)
      exact_target="=$target_session:=$target_window"
      fm_backend_source tmux || {
        record_outcome "task $id: skipped - live endpoint worktree identity is unreadable"
        return 1
      }
      live=$(fm_backend_tmux_current_path "$exact_target")
      ;;
    herdr)
      fm_backend_source herdr || {
        record_outcome "task $id: skipped - live endpoint worktree identity is unreadable"
        return 1
      }
      live=$(fm_backend_herdr_current_path "$target")
      ;;
    *)
      record_outcome "task $id: skipped - backend '$backend' has no verified legacy task worktree identity"
      return 1
      ;;
  esac
  [ -n "$live" ] || {
    record_outcome "task $id: skipped - live endpoint worktree identity is unreadable"
    return 1
  }
  state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unreadable')
  [ "$state" = alive ] || {
    record_endpoint_state_refusal "$id" "$backend" "$state"
    return 1
  }
  recorded_real=$(CDPATH='' cd -- "$recorded" 2>/dev/null && pwd -P) || {
    record_outcome "task $id: skipped - recorded task worktree identity is unreadable"
    return 1
  }
  live_real=$(CDPATH='' cd -- "$live" 2>/dev/null && pwd -P) || {
    record_outcome "task $id: skipped - live endpoint worktree identity is unreadable"
    return 1
  }
  [ "$live_real" = "$recorded_real" ] || {
    record_outcome "task $id: skipped - task identity mismatch: live endpoint worktree does not match recorded worktree"
    return 1
  }
  FM_ENDPOINT_VERIFIED_WORKTREE=$recorded_real
}

verify_legacy_endpoint() {
  local meta=$1 id=$2 backend target state validation
  backend=$(fm_backend_of_meta "$meta")
  if [ "$backend" = herdr ] && ! verify_legacy_herdr_label "$meta" "$id"; then
    return 1
  fi
  if validation=$(fm_backend_validate_task_endpoint "$meta" "$id" 2>&1); then
    if ! fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1; then
      record_outcome "task $id: skipped - shared endpoint metadata changed during validation"
      return 1
    fi
  else
    record_outcome "task $id: skipped - shared endpoint validation refused: $(reason_one_line "$validation")"
    return 1
  fi
  backend=$FM_BACKEND_VALIDATED_BACKEND
  target=$FM_BACKEND_VALIDATED_TARGET
  [ -n "$backend" ] && [ -n "$target" ] || {
    record_outcome "task $id: skipped - identity mismatch: backend target was empty"
    return 1
  }
  state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unreadable')
  [ "$state" = alive ] || {
    record_endpoint_state_refusal "$id" "$backend" "$state"
    return 1
  }
  verify_live_task_worktree "$meta" "$id" "$backend" "$target"
}

verify_legacy_herdr_label() {
  local meta=$1 id=$2 target session live_target live_label live_count=0 recorded_target
  target=$(fm_backend_meta_exact_value "$meta" window) || {
    record_outcome "task $id: skipped - shared endpoint validation refused: REFUSED: legacy Herdr endpoint metadata lacks an exact live task label; preserving task state."
    return 1
  }
  session=${target%%:*}
  fm_backend_source herdr || {
    record_outcome "task $id: skipped - shared endpoint validation refused: REFUSED: legacy Herdr endpoint metadata lacks an exact live task label; preserving task state."
    return 1
  }
  while IFS=$'\t' read -r live_target live_label; do
    [ "$live_label" = "fm-$id" ] || continue
    live_count=$((live_count + 1))
    target=$live_target
  done < <(fm_backend_herdr_list_live "$session")
  if [ "$live_count" -eq 0 ]; then
    record_outcome "task $id: skipped - shared endpoint validation refused: REFUSED: legacy Herdr endpoint metadata lacks an exact live task label; preserving task state."
    return 1
  fi
  if [ "$live_count" -ne 1 ]; then
    record_outcome "task $id: skipped - shared endpoint validation refused: REFUSED: legacy Herdr endpoint has an ambiguous live fm-$id label; preserving task state."
    return 1
  fi
  recorded_target=$(fm_backend_meta_exact_value "$meta" window) || return 1
  if [ "$target" != "$recorded_target" ]; then
    record_outcome "task $id: skipped - shared endpoint validation refused: REFUSED: live fm-$id label resolves to a different Herdr endpoint; preserving task state."
    return 1
  fi
}

endpoint_claim_conflicts() {
  local meta=$1 id=$2 backend=$3 target=$4 worktree=$5
  local other other_id other_backend other_target other_worktree
  for other in "$STATE"/*.meta; do
    [ "$other" = "$meta" ] && continue
    regular_file "$other" || continue
    other_id=$(basename "$other" .meta)
    [ "$other_id" = "$id" ] && continue
    other_backend=$(fm_backend_of_meta "$other")
    other_target=$(fm_backend_target_of_meta "$other")
    other_worktree=$(fm_meta_get "$other" worktree)
    other_worktree=$(CDPATH='' cd -- "$other_worktree" 2>/dev/null && pwd -P || true)
    if [ "$backend" = "$other_backend" ] && [ "$target" = "$other_target" ]; then
      return 0
    fi
    if [ "$backend" = herdr ] && [ "$other_backend" = herdr ] \
      && [ -n "$worktree" ] && [ "$worktree" = "$other_worktree" ]; then
      return 0
    fi
  done
  return 1
}

candidate_for() {
  local meta=$1 id=$2 candidate=$3
  cp -- "$meta" "$candidate" || return 1
  if [ -s "$candidate" ] && [ "$(tail -c 1 "$candidate")" != $'\n' ]; then
    printf '\n' >> "$candidate" || return 1
  fi
  printf 'endpoint_task_id=%s\n' "$id" >> "$candidate" || return 1
  chmod 600 "$candidate"
}

publish_candidate() {
  local meta=$1 id=$2 candidate=$3 binding_count binding
  regular_file "$meta" || return 1
  binding_count=$(grep -c '^endpoint_task_id=' "$meta" 2>/dev/null || true)
  [ "$binding_count" -eq 0 ] || return 2
  mv -f -- "$candidate" "$meta" || return 1
  regular_file "$meta" || return 1
  binding_count=$(grep -c '^endpoint_task_id=' "$meta" 2>/dev/null || true)
  binding=$(fm_meta_get "$meta" endpoint_task_id)
  [ "$binding_count" -eq 1 ] && [ "$binding" = "$id" ]
}

OUTCOME_COUNT=0
STAMP_COUNT=0
candidate=
cleanup() {
  rm -f -- "$candidate" 2>/dev/null || true
}
clear_temp() {
  rm -f -- "$candidate" 2>/dev/null || true
  candidate=
}
trap cleanup EXIT
trap 'exit 143' HUP INT TERM

require_session_lock || exit 1

shopt -s nullglob
for stale in "$STATE"/.fm-endpoint-binding-candidate.*; do
  [ -e "$stale" ] || [ -L "$stale" ] || continue
  rm -f -- "$stale" || exit 1
done
for meta in "$STATE"/*.meta; do
  base=$(basename "$meta")
  id=$(basename "$meta" .meta)
  if [ -L "$meta" ]; then
    record_outcome "task $(reason_one_line "$id"): skipped - metadata record is a symlink; endpoint identity is unverifiable"
    continue
  fi
  if [ ! -f "$meta" ]; then
    record_outcome "task $(reason_one_line "$id"): skipped - metadata record is not a regular file; endpoint identity is unverifiable"
    continue
  fi
  if ! valid_task_id "$id"; then
    record_outcome "task $(reason_one_line "$id"): skipped - invalid task id"
    continue
  fi
  require_session_lock || exit 1
  meta_lock=$(fm_meta_lock_path "$meta") || exit 1
  fm_lock_acquire_wait "$meta_lock" || exit 1
  if ! regular_file "$meta" || ! cat -- "$meta" >/dev/null 2>&1; then
    record_outcome "task $id: skipped - metadata record is unreadable; endpoint identity is unverifiable"
    fm_lock_release "$meta_lock" || exit 1
    continue
  fi
  binding_count=$(grep -c '^endpoint_task_id=' "$meta" 2>/dev/null || true)
  if [ "$binding_count" -gt 0 ]; then
    binding=$(fm_meta_get "$meta" endpoint_task_id)
    if [ "$binding_count" -eq 1 ] && [ "$binding" = "$id" ]; then
      record_outcome "task $id: untouched - endpoint_task_id already present"
    elif [ "$binding_count" -gt 1 ]; then
      record_outcome "task $id: skipped - existing endpoint_task_id binding is duplicated"
    elif [ -z "$binding" ]; then
      record_outcome "task $id: skipped - existing endpoint_task_id binding is empty"
    else
      record_outcome "task $id: skipped - existing endpoint_task_id binding mismatches task identity"
    fi
    fm_lock_release "$meta_lock" || exit 1
    continue
  fi
  candidate=$(mktemp "$STATE/.fm-endpoint-binding-candidate.XXXXXX") || {
    fm_lock_release "$meta_lock" || true
    exit 1
  }
  candidate_for "$meta" "$id" "$candidate" || {
    fm_lock_release "$meta_lock" || true
    exit 1
  }
  if ! verify_legacy_endpoint "$candidate" "$id"; then
    clear_temp
    fm_lock_release "$meta_lock" || exit 1
    continue
  fi
  if endpoint_claim_conflicts "$meta" "$id" "$FM_BACKEND_VALIDATED_BACKEND" \
    "$FM_BACKEND_VALIDATED_TARGET" "$FM_ENDPOINT_VERIFIED_WORKTREE"; then
    record_outcome "task $id: skipped - ambiguous live endpoint identity is claimed by multiple task records"
    clear_temp
    fm_lock_release "$meta_lock" || exit 1
    continue
  fi
  require_session_lock || {
    fm_lock_release "$meta_lock" || true
    exit 1
  }
  if ! verify_legacy_endpoint "$candidate" "$id"; then
    clear_temp
    fm_lock_release "$meta_lock" || exit 1
    continue
  fi
  publish_candidate "$meta" "$id" "$candidate"
  publish_rc=$?
  if [ "$publish_rc" -eq 2 ]; then
    record_outcome "task $id: skipped - metadata changed during scan; rerun migration"
  elif [ "$publish_rc" -ne 0 ]; then
    fm_lock_release "$meta_lock" || true
    exit 1
  else
    record_outcome "task $id: stamped - exact live endpoint identity verified"
    STAMP_COUNT=$((STAMP_COUNT + 1))
  fi
  clear_temp
  fm_lock_release "$meta_lock" || exit 1
done

printf 'ENDPOINT_BINDING_MIGRATION: scanned %s record(s); stamped %s\n' "$OUTCOME_COUNT" "$STAMP_COUNT"
