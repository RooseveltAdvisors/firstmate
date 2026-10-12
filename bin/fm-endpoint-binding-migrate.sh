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

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
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

FM_ENDPOINT_VERIFIED_WORKTREE=
verify_live_task_worktree() {
  local meta=$1 backend=$2 target=$3 recorded live recorded_real live_real exact_target state
  local target_session target_window
  FM_ENDPOINT_VERIFIED_WORKTREE=
  recorded=$(fm_backend_meta_exact_value "$meta" worktree) || return 1
  case "$backend" in
    tmux)
      target_session=$(printf '%s' "$target" | cut -d: -f1)
      target_window=$(printf '%s' "$target" | cut -d: -f2-)
      exact_target="=$target_session:=$target_window"
      fm_backend_source tmux || return 1
      live=$(fm_backend_tmux_current_path "$exact_target")
      ;;
    herdr)
      fm_backend_source herdr || return 1
      live=$(fm_backend_herdr_current_path "$target")
      ;;
    *) return 1 ;;
  esac
  [ -n "$live" ] || return 1
  state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unreadable')
  [ "$state" = alive ] || {
    [ "$state" != dead ] || ENDPOINT_DEAD=1
    return 1
  }
  recorded_real=$(CDPATH='' cd -- "$recorded" 2>/dev/null && pwd -P) || return 1
  live_real=$(CDPATH='' cd -- "$live" 2>/dev/null && pwd -P) || return 1
  [ "$live_real" = "$recorded_real" ] || return 1
  FM_ENDPOINT_VERIFIED_WORKTREE=$recorded_real
}

verify_legacy_endpoint() {
  local meta=$1 id=$2 backend target state
  backend=$(fm_backend_of_meta "$meta")
  if [ "$backend" = herdr ] && ! verify_legacy_herdr_label "$meta" "$id"; then
    return 1
  fi
  fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1 || return 1
  fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1 || return 1
  backend=$FM_BACKEND_VALIDATED_BACKEND
  target=$FM_BACKEND_VALIDATED_TARGET
  [ -n "$backend" ] && [ -n "$target" ] || return 1
  state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unreadable')
  [ "$state" = alive ] || {
    [ "$state" != dead ] || ENDPOINT_DEAD=1
    return 1
  }
  verify_live_task_worktree "$meta" "$backend" "$target"
}

verify_legacy_herdr_label() {
  local meta=$1 id=$2 target session live_target live_label live_count=0 recorded_target
  target=$(fm_backend_meta_exact_value "$meta" window) || return 1
  session=${target%%:*}
  fm_backend_source herdr || return 1
  while IFS=$'\t' read -r live_target live_label; do
    [ "$live_label" = "fm-$id" ] || continue
    live_count=$((live_count + 1))
    target=$live_target
  done < <(fm_backend_herdr_list_live "$session")
  [ "$live_count" -eq 1 ] || return 1
  recorded_target=$(fm_backend_meta_exact_value "$meta" window) || return 1
  [ "$target" = "$recorded_target" ]
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
  local meta=$1 line=$2 candidate=$3
  line=$line awk '
    !inserted && /^pr=/ { print ENVIRON["line"]; inserted = 1 }
    { print }
    END { if (!inserted) print ENVIRON["line"] }
  ' "$meta" > "$candidate" || return 1
  chmod 600 "$candidate"
}

unmigrated() {
  ! grep -q '^endpoint_task_id=\|^endpoint_binding_verdict=' "$1" 2>/dev/null
}

publish_candidate() {
  local meta=$1 key=$2 value=$3 candidate=$4
  regular_file "$meta" || return 1
  unmigrated "$meta" || return 2
  mv -f -- "$candidate" "$meta" || return 1
  regular_file "$meta" || return 1
  [ "$(grep -c "^$key=" "$meta" 2>/dev/null || true)" -eq 1 ] \
    && [ "$(fm_meta_get "$meta" "$key")" = "$value" ]
}

STAMP_COUNT=0
REFUSE_COUNT=0
# ponytail: fixed per-start probe cap in glob order; retryable records past the cap wait for a start where earlier ones resolve.
PROBE_BUDGET=16
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

shopt -s nullglob dotglob
for stale in "$STATE"/.fm-endpoint-binding-candidate.*; do
  [ -e "$stale" ] || [ -L "$stale" ] || continue
  rm -f -- "$stale" || exit 1
done
for meta in "$STATE"/*.meta; do
  base=${meta##*/}
  case "$base" in
    .*) continue ;;
  esac
  id=$(basename "$meta" .meta)
  if ! regular_file "$meta" || ! valid_task_id "$id" || ! unmigrated "$meta"; then
    continue
  fi
  [ "$PROBE_BUDGET" -gt 0 ] || break
  require_session_lock || exit 1
  meta_lock=$(fm_meta_lock_path "$meta") || exit 1
  fm_lock_try_acquire "$meta_lock" || continue
  if ! regular_file "$meta" || ! cat -- "$meta" >/dev/null 2>&1; then
    fm_lock_release "$meta_lock" || exit 1
    continue
  fi
  PROBE_BUDGET=$((PROBE_BUDGET - 1))
  candidate=$(mktemp "$STATE/.fm-endpoint-binding-candidate.XXXXXX") || {
    fm_lock_release "$meta_lock" || true
    exit 1
  }
  candidate_for "$meta" "endpoint_task_id=$id" "$candidate" || {
    fm_lock_release "$meta_lock" || true
    exit 1
  }
  ENDPOINT_DEAD=0
  verified=0
  if verify_legacy_endpoint "$candidate" "$id"; then
    if ! endpoint_claim_conflicts "$meta" "$id" "$FM_BACKEND_VALIDATED_BACKEND" \
      "$FM_BACKEND_VALIDATED_TARGET" "$FM_ENDPOINT_VERIFIED_WORKTREE"; then
      require_session_lock || {
        fm_lock_release "$meta_lock" || true
        exit 1
      }
      verify_legacy_endpoint "$candidate" "$id" && verified=1
    fi
  fi
  if [ "$verified" -eq 1 ]; then
    key=endpoint_task_id
    value=$id
  elif [ "$ENDPOINT_DEAD" -eq 1 ]; then
    key=endpoint_binding_verdict
    value="terminal: dead endpoint"
    candidate_for "$meta" "$key=$value" "$candidate" || {
      fm_lock_release "$meta_lock" || true
      exit 1
    }
  else
    clear_temp
    fm_lock_release "$meta_lock" || exit 1
    continue
  fi
  publish_candidate "$meta" "$key" "$value" "$candidate"
  publish_rc=$?
  if [ "$publish_rc" -eq 0 ] && [ "$verified" -eq 1 ]; then
    STAMP_COUNT=$((STAMP_COUNT + 1))
  elif [ "$publish_rc" -eq 0 ]; then
    REFUSE_COUNT=$((REFUSE_COUNT + 1))
  elif [ "$publish_rc" -ne 2 ]; then
    fm_lock_release "$meta_lock" || true
    exit 1
  fi
  clear_temp
  fm_lock_release "$meta_lock" || exit 1
done

if [ $((STAMP_COUNT + REFUSE_COUNT)) -gt 0 ]; then
  printf 'ENDPOINT_BINDING_MIGRATION: stamped %s; refused %s (terminal reason recorded as endpoint_binding_verdict in each refused record)\n' \
    "$STAMP_COUNT" "$REFUSE_COUNT"
fi
