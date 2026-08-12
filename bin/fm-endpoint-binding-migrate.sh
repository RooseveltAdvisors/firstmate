#!/usr/bin/env bash
# Evidence-bound migration for legacy task metadata without endpoint_task_id.
# Only a live, exact endpoint identity may be stamped. Every stamp is staged,
# recorded with its before/after bytes, and reversible with --undo.
# Usage: fm-endpoint-binding-migrate.sh [--undo]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REPORT="$STATE/.endpoint-binding-migration.log"
SCAN_MARKER="$STATE/.endpoint-binding-migration-scan-v1"
MARKER="$STATE/.endpoint-binding-migration-v1"
RECORDS="$STATE/.endpoint-binding-migration-records-v1"
BACKUP_DIR="$STATE/.endpoint-binding-migration-backups"
MIGRATION_LOCK="$STATE/.endpoint-binding-migration.lock"
MODE=apply

case "${1:-}" in
  '') ;;
  --undo) MODE=undo ;;
  --help|-h)
    sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'
    exit 0
    ;;
  *)
    echo "ENDPOINT_BINDING_MIGRATION: invalid argument '$1'" >&2
    exit 2
    ;;
esac

# shellcheck source=bin/fm-session-lock-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

umask 077
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
require_session_lock || exit 1
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

valid_task_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

file_mode() {
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

regular_file() {
  [ -f "$1" ] && [ ! -L "$1" ]
}

private_file() {
  regular_file "$1" && [ "$(file_mode "$1" 2>/dev/null)" = 600 ]
}

private_directory() {
  [ -d "$1" ] && [ ! -L "$1" ] && [ "$(file_mode "$1" 2>/dev/null)" = 700 ]
}

directory_empty() {
  local path
  for path in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    return 1
  done
  return 0
}

list_contains() {
  local needle=$1 value
  shift
  for value in "$@"; do
    [ "$value" = "$needle" ] && return 0
  done
  return 1
}

recorded_id_add() {
  list_contains "$1" "${RECORDED_IDS[@]}" || RECORDED_IDS+=("$1")
}

recorded_id_contains() {
  list_contains "$1" "${RECORDED_IDS[@]}"
}

write_marker() {
  local destination=$1 value=$2 tmp
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    [ -f "$destination" ] && [ ! -L "$destination" ] || return 1
  fi
  tmp=$(mktemp "$STATE/.endpoint-binding-marker.XXXXXX") || return 1
  if ! private_file "$tmp" || ! append_private_line_atomic "$tmp" "$value" \
    || ! copy_private_atomic "$tmp" "$destination" regular; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp" || return 1
}

record_outcome() {
  if ! append_private_line_atomic "$REPORT_TMP" "$1"; then
    REPORT_WRITE_FAILED=1
    return 1
  fi
  OUTCOME_COUNT=$((OUTCOME_COUNT + 1))
}

reason_one_line() {
  local value=${1:-endpoint identity verification refused} byte character encoded=
  [ -n "$value" ] || value='endpoint identity verification refused'
  for byte in $(printf '%s' "$value" | LC_ALL=C od -An -v -t u1); do
    if [ "$byte" -lt 32 ] || [ "$byte" -ge 127 ]; then
      printf -v character '\\x%02X' "$byte"
    else
      printf -v character '%b' "\\$(printf '%03o' "$byte")"
    fi
    encoded=$encoded$character
  done
  printf '%s' "$encoded"
}

record_endpoint_state_refusal() {
  local id=$1 backend=$2 state=$3
  case "$state" in
    dead)
      record_outcome "task $id: skipped - dead endpoint (no verified agent is running)"
      ;;
    missing)
      record_outcome "task $id: skipped - dead endpoint (recorded target is missing)"
      ;;
    ambiguous)
      record_outcome "task $id: skipped - ambiguous live endpoint identity"
      ;;
    unreadable)
      record_outcome "task $id: skipped - endpoint identity is unreadable"
      ;;
    unverified)
      record_outcome "task $id: skipped - backend '$backend' has no verified endpoint identity"
      ;;
    *)
      record_outcome "task $id: skipped - endpoint identity returned unexpected state '$state'"
      ;;
  esac
  return 1
}

verify_live_task_worktree() {
  local meta=$1 id=$2 backend=$3 target=$4 recorded live recorded_real live_real exact_target state
  recorded=$(fm_backend_meta_exact_value "$meta" worktree) || {
    record_outcome "task $id: skipped - recorded task worktree identity is unreadable"
    return 1
  }
  case "$backend" in
    tmux)
      exact_target="=${target%%:*}:=${target#*:}"
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
}

verify_legacy_endpoint() {
  local meta=$1 id=$2 backend target state validation
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
  if [ -z "$backend" ] || [ -z "$target" ]; then
    record_outcome "task $id: skipped - identity mismatch: backend target was empty"
    return 1
  fi
  # fm_backend_agent_state is the recovery-grade live endpoint read. Its
  # inventory check prevents tmux's absent-target fallback from inspecting the
  # active window, and its ambiguous/unreadable states never license a stamp.
  state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unreadable')
  if [ "$state" = alive ]; then
    verify_live_task_worktree "$meta" "$id" "$backend" "$target"
    return $?
  fi
  record_endpoint_state_refusal "$id" "$backend" "$state"
}

STAGE_DIR=
REPORT_TMP=
STAMP_IDS=()
STAMP_METAS=()
STAMP_BEFORE=()
STAMP_AFTER=()
STAMP_BACKENDS=()
STAMP_TARGETS=()
STAMP_BEFORE_FINAL=()
STAMP_AFTER_FINAL=()
STAMP_SELECTED=()
OUTCOME_COUNT=0
REPORT_WRITE_FAILED=0
SKIPPED_LEGACY=0
META_WRITE_STARTED=0
RECORDS_PUBLISHED=0
BACKUP_DIR_CREATED=0
CURRENT_META_LOCK=
CURRENT_META_LOCK_HELD=0
REPORT_BEFORE=
SCAN_MARKER_BEFORE=
MARKER_BEFORE=
REPORT_PRESENT=0
SCAN_MARKER_PRESENT=0
MARKER_PRESENT=0
REPORT_SNAPSHOT_READY=0
SCAN_MARKER_SNAPSHOT_READY=0
MARKER_SNAPSHOT_READY=0
RECOVERY_REQUIRED=0
APPLY_ABORTED=0
APPLY_COMMITTED=0
RECOVERY_NAMESPACE_PRESENT=0
RECORDS_EXISTING=0
RECORDS_BEFORE=
RECORDED_IDS=()
UNDO_IDS=()
UNDO_METAS=()
UNDO_BEFORE=()
UNDO_AFTER=()
UNDO_TOUCHED=()
UNDO_CHANGED=0
UNDO_ACTIVE=0
UNDO_LOCK_IDS=()
UNDO_LOCK_PATHS=()
UNDO_LOCK_ACQUIRED=()
UNDO_LOCKS_HELD=0
UNDO_LOCKS_ACQUIRING=0
UNDO_RECOVERY_AFTER=()
UNDO_RECOVERY_BEFORE=()
UNDO_RECOVERY_STAGE=
MERGE_LOCK_IDS=()
MERGE_LOCK_PATHS=()
MERGE_LOCK_ACQUIRED=()
APPLY_LOCK_IDS=()
APPLY_LOCK_PATHS=()
APPLY_LOCK_ACQUIRED=()
APPLY_LOCKS_HELD=0
MIGRATION_LOCK_HELD=0
SURGICAL_UNDO_CHANGED=0

release_migration_lock() {
  if [ "$MIGRATION_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$MIGRATION_LOCK"
    MIGRATION_LOCK_HELD=0
  fi
}

cleanup() {
  release_apply_locks || true
  release_merge_locks || true
  release_undo_locks || true
  if [ "$RECOVERY_REQUIRED" -eq 0 ]; then
    [ -z "$REPORT_TMP" ] || rm -f -- "$REPORT_TMP"
    if [ -n "$STAGE_DIR" ] && [ ! -L "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
      remove_stage_directory "$STAGE_DIR" || true
    fi
  fi
  release_migration_lock || true
}
trap cleanup EXIT

acquire_meta_lock() {
  CURRENT_META_LOCK=$(fm_meta_lock_path "$1") || return 1
  CURRENT_META_LOCK_HELD=1
  if ! fm_lock_acquire_wait "$CURRENT_META_LOCK"; then
    CURRENT_META_LOCK=
    CURRENT_META_LOCK_HELD=0
    return 1
  fi
  if ! require_session_lock; then
    fm_lock_release "$CURRENT_META_LOCK" || true
    CURRENT_META_LOCK=
    CURRENT_META_LOCK_HELD=0
    return 1
  fi
}

release_meta_lock() {
  local rc=0
  if [ "$CURRENT_META_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CURRENT_META_LOCK" || rc=1
    CURRENT_META_LOCK=
    CURRENT_META_LOCK_HELD=0
  fi
  return "$rc"
}

acquire_undo_locks() {
  local id path i
  # shellcheck disable=SC2207
  UNDO_LOCK_IDS=($(printf '%s\n' "${UNDO_IDS[@]}" | sort -u))
  UNDO_LOCK_PATHS=()
  UNDO_LOCK_ACQUIRED=()
  for id in "${UNDO_LOCK_IDS[@]}"; do
    path=$(fm_meta_lock_path "$STATE/$id.meta") || return 1
    UNDO_LOCK_PATHS+=("$path")
    UNDO_LOCK_ACQUIRED+=(0)
  done
  UNDO_LOCKS_ACQUIRING=1
  for i in "${!UNDO_LOCK_PATHS[@]}"; do
    UNDO_LOCK_ACQUIRED[i]=1
    if ! fm_lock_acquire_wait "${UNDO_LOCK_PATHS[$i]}" || ! require_session_lock; then
      release_undo_locks
      return 1
    fi
  done
  UNDO_LOCKS_ACQUIRING=0
  UNDO_LOCKS_HELD=1
}

release_undo_locks() {
  local i rc=0
  for ((i=${#UNDO_LOCK_PATHS[@]} - 1; i >= 0; i--)); do
    if [ "${UNDO_LOCK_ACQUIRED[$i]:-0}" -eq 1 ]; then
      fm_lock_release "${UNDO_LOCK_PATHS[$i]}" || rc=1
      UNDO_LOCK_ACQUIRED[i]=0
    fi
  done
  UNDO_LOCKS_HELD=0
  UNDO_LOCKS_ACQUIRING=0
  return "$rc"
}

acquire_apply_locks() {
  local id path i
  # shellcheck disable=SC2207
  APPLY_LOCK_IDS=($(printf '%s\n' "${STAMP_IDS[@]}" | sort -u))
  APPLY_LOCK_PATHS=()
  APPLY_LOCK_ACQUIRED=()
  for id in "${APPLY_LOCK_IDS[@]}"; do
    path=$(fm_meta_lock_path "$STATE/$id.meta") || return 1
    APPLY_LOCK_PATHS+=("$path")
    APPLY_LOCK_ACQUIRED+=(0)
  done
  for i in "${!APPLY_LOCK_PATHS[@]}"; do
    APPLY_LOCK_ACQUIRED[i]=1
    if ! fm_lock_acquire_wait "${APPLY_LOCK_PATHS[$i]}" || ! require_session_lock; then
      release_apply_locks
      return 1
    fi
  done
  APPLY_LOCKS_HELD=1
}

release_apply_locks() {
  local i rc=0
  for ((i=${#APPLY_LOCK_PATHS[@]} - 1; i >= 0; i--)); do
    if [ "${APPLY_LOCK_ACQUIRED[$i]:-0}" -eq 1 ]; then
      fm_lock_release "${APPLY_LOCK_PATHS[$i]}" || rc=1
      APPLY_LOCK_ACQUIRED[i]=0
    fi
  done
  APPLY_LOCKS_HELD=0
  return "$rc"
}

acquire_merge_locks() {
  local id path i
  [ "$RECORDS_EXISTING" -eq 1 ] || [ "$RECOVERY_NAMESPACE_PRESENT" -eq 1 ] || [ "${1:-0}" -eq 1 ] || return 0
  # shellcheck disable=SC2207
  MERGE_LOCK_IDS=($(printf '%s\n' "${RECORDED_IDS[@]}" | sort -u))
  MERGE_LOCK_PATHS=()
  MERGE_LOCK_ACQUIRED=()
  for id in "${MERGE_LOCK_IDS[@]}"; do
    path=$(fm_meta_lock_path "$STATE/$id.meta") || return 1
    MERGE_LOCK_PATHS+=("$path")
    MERGE_LOCK_ACQUIRED+=(0)
  done
  for i in "${!MERGE_LOCK_PATHS[@]}"; do
    MERGE_LOCK_ACQUIRED[i]=1
    if ! fm_lock_acquire_wait "${MERGE_LOCK_PATHS[$i]}" || ! require_session_lock; then
      release_merge_locks
      return 1
    fi
  done
}

release_merge_locks() {
  local i rc=0
  for ((i=${#MERGE_LOCK_PATHS[@]} - 1; i >= 0; i--)); do
    if [ "${MERGE_LOCK_ACQUIRED[$i]:-0}" -eq 1 ]; then
      fm_lock_release "${MERGE_LOCK_PATHS[$i]}" || rc=1
      MERGE_LOCK_ACQUIRED[i]=0
    fi
  done
  return "$rc"
}

valid_stamp_evidence() {
  local id=$1 before=$2 after=$3 expected
  private_file "$before" && private_file "$after" || return 1
  ! grep -q '^endpoint_task_id=' "$before" || return 1
  expected=$(mktemp "$STATE/.endpoint-binding-evidence-check.XXXXXX") || return 1
  if ! copy_private_atomic "$before" "$expected" private private "$id"; then
    rm -f -- "$expected"
    return 1
  fi
  if ! cmp -s -- "$expected" "$after"; then
    rm -f -- "$expected"
    return 1
  fi
  rm -f -- "$expected"
}

revalidate_merge_records() {
  local id before after
  [ "$RECORDS_EXISTING" -eq 1 ] || [ "$RECOVERY_NAMESPACE_PRESENT" -eq 1 ] || [ "${1:-0}" -eq 1 ] || return 0
  for id in "${MERGE_LOCK_IDS[@]}"; do
    before="$BACKUP_DIR/$id.before"
    after="$BACKUP_DIR/$id.after"
    valid_stamp_evidence "$id" "$before" "$after" || return 1
  done
}

rollback_stamps() {
  local i rc=0 meta lock_held
  lock_held=$APPLY_LOCKS_HELD
  for i in "${!STAMP_IDS[@]}"; do
    [ "${STAMP_SELECTED[$i]:-0}" -eq 1 ] || continue
    meta=${STAMP_METAS[$i]}
    if [ "$lock_held" -eq 0 ] && ! acquire_meta_lock "$meta"; then
      rc=1
      continue
    fi
    if ! regular_file "$meta"; then
      rc=1
      [ "$lock_held" -eq 1 ] || release_meta_lock || rc=1
      continue
    fi
    if cmp -s -- "$meta" "${STAMP_BEFORE[$i]}"; then
      [ "$lock_held" -eq 1 ] || release_meta_lock || rc=1
      continue
    fi
    if ! cmp -s -- "$meta" "${STAMP_AFTER[$i]}"; then
      rc=1
      [ "$lock_held" -eq 1 ] || release_meta_lock || rc=1
      continue
    fi
    copy_private_atomic "${STAMP_BEFORE[$i]}" "${STAMP_METAS[$i]}" regular || rc=1
    [ "$lock_held" -eq 1 ] || release_meta_lock || rc=1
  done
  return "$rc"
}

remove_published_backups() {
  local i rc=0
  if [ ! -e "$BACKUP_DIR" ] && [ ! -L "$BACKUP_DIR" ]; then
    [ "$BACKUP_DIR_CREATED" -eq 0 ]
    return $?
  fi
  for i in "${!STAMP_IDS[@]}"; do
    [ "${STAMP_SELECTED[$i]:-1}" -eq 1 ] || continue
    remove_private_backup_files "${STAMP_BEFORE_FINAL[$i]}" "${STAMP_AFTER_FINAL[$i]}" || rc=1
  done
  if [ "$BACKUP_DIR_CREATED" -eq 1 ]; then
    if [ -e "$BACKUP_DIR" ] || [ -L "$BACKUP_DIR" ]; then
      private_directory "$BACKUP_DIR" || rc=1
      [ "$rc" -ne 0 ] || rmdir -- "$BACKUP_DIR" 2>/dev/null || rc=1
    else
      rc=1
    fi
  fi
  return "$rc"
}

remove_private_backup_files() {
  local before=$1 after=$2 before_name after_name backup_real backup_parent backup_base backup_expected
  before_name=${before##*/}
  after_name=${after##*/}
  [ -L "$BACKUP_DIR" ] && return 1
  backup_parent=${BACKUP_DIR%/*}
  backup_base=${BACKUP_DIR##*/}
  backup_expected=$(cd -P -- "$backup_parent" && pwd -P)/$backup_base || return 1
  backup_real=$(cd -P -- "$BACKUP_DIR" && pwd -P) || return 1
  [ "$backup_real" = "$backup_expected" ] || return 1
  (
    cd -P -- "$BACKUP_DIR" || exit 1
    [ "$(pwd -P)" = "$backup_expected" ] || exit 1
    private_directory . || exit 1
    if [ -e "./$before_name" ] || [ -L "./$before_name" ]; then
      private_file "./$before_name" || exit 1
    fi
    if [ -e "./$after_name" ] || [ -L "./$after_name" ]; then
      private_file "./$after_name" || exit 1
    fi
    rm -f -- "./$before_name" "./$after_name"
  )
}

restore_published_backups() {
  local i rc=0
  if [ -e "$BACKUP_DIR" ] || [ -L "$BACKUP_DIR" ]; then
    private_directory "$BACKUP_DIR" || return 1
  else
    mkdir -- "$BACKUP_DIR" || return 1
    BACKUP_DIR_CREATED=1
  fi
  private_directory "$BACKUP_DIR" || return 1
  for i in "${!STAMP_IDS[@]}"; do
    [ "${STAMP_SELECTED[$i]:-1}" -eq 1 ] || continue
    copy_private_atomic "${STAMP_BEFORE[$i]}" "${STAMP_BEFORE_FINAL[$i]}" || rc=1
    copy_private_atomic "${STAMP_AFTER[$i]}" "${STAMP_AFTER_FINAL[$i]}" || rc=1
  done
  return "$rc"
}

atomic_rename_nofollow() {
  case "$(uname 2>/dev/null || true)" in
    Darwin) mv -fh -- "$1" "$2" ;;
    Linux) mv -fT -- "$1" "$2" ;;
    *) return 1 ;;
  esac
}

path_file_identity() {
  case "$(uname 2>/dev/null || true)" in
    Darwin) stat -f '%d:%i' "$1" ;;
    *) stat -c '%d:%i' "$1" ;;
  esac
}

file_descriptor_identity() {
  case "$(uname 2>/dev/null || true)" in
    Darwin) stat -L -f '%d:%i' "$1" ;;
    *) stat -L -c '%d:%i' "$1" ;;
  esac
}

copy_to_new_private_file() {
  local source=$1 destination=$2 source_type=${3:-private} binding_id=${4:-}
  local append_line=${5:-} append_source=${6:-} append_source_type=${7:-private}
  local append_skip=${8:-0} append_separator=${9:-0}
  local source_identity source_fd_identity binding_fd_identity destination_identity destination_fd_identity
  local append_identity append_fd_identity last_byte
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 1
  if [ "$source_type" = regular ]; then
    regular_file "$source" || return 1
  else
    private_file "$source" || return 1
  fi
  case "$append_skip:$append_separator" in
    *[!0-9:]*|:*) return 1 ;;
  esac
  if [ -n "$append_source" ]; then
    if [ "$append_source_type" = regular ]; then
      regular_file "$append_source" || return 1
    else
      private_file "$append_source" || return 1
    fi
    append_identity=$(path_file_identity "$append_source" 2>/dev/null) || return 1
  fi
  source_identity=$(path_file_identity "$source" 2>/dev/null) || return 1
  destination_identity=$(
    exec 8< "$source" || exit 1
    [ -f /dev/fd/8 ] || exit 1
    source_fd_identity=$(file_descriptor_identity /dev/fd/8 2>/dev/null) || exit 1
    [ "$source_fd_identity" = "$source_identity" ] || exit 1
    if [ -n "$binding_id" ]; then
      exec 7< "$source" || exit 1
      [ -f /dev/fd/7 ] || exit 1
      binding_fd_identity=$(file_descriptor_identity /dev/fd/7 2>/dev/null) || exit 1
      [ "$binding_fd_identity" = "$source_identity" ] || exit 1
    fi
    if [ -n "$append_source" ]; then
      exec 6< "$append_source" || exit 1
      [ -f /dev/fd/6 ] || exit 1
      append_fd_identity=$(file_descriptor_identity /dev/fd/6 2>/dev/null) || exit 1
      [ "$append_fd_identity" = "$append_identity" ] || exit 1
    fi
    if [ "$source_type" = regular ]; then
      regular_file "$source" || exit 1
    else
      private_file "$source" || exit 1
    fi
    [ "$(path_file_identity "$source" 2>/dev/null)" = "$source_fd_identity" ] || exit 1
    if [ -n "$append_source" ]; then
      if [ "$append_source_type" = regular ]; then
        regular_file "$append_source" || exit 1
      else
        private_file "$append_source" || exit 1
      fi
      [ "$(path_file_identity "$append_source" 2>/dev/null)" = "$append_fd_identity" ] || exit 1
    fi
    set -C
    exec 9> "$destination" || exit 1
    [ -f /dev/fd/9 ] || exit 1
    destination_fd_identity=$(file_descriptor_identity /dev/fd/9 2>/dev/null) || exit 1
    regular_file "$destination" || exit 1
    [ "$(path_file_identity "$destination" 2>/dev/null)" = "$destination_fd_identity" ] || exit 1
    cat <&8 >&9 || exit 1
    if [ -n "$binding_id" ]; then
      if [ -s /dev/fd/7 ]; then
        last_byte=$(tail -c 1 <&7) || exit 1
        [ -z "$last_byte" ] || printf '\n' >&9 || exit 1
      fi
      printf 'endpoint_task_id=%s\n' "$binding_id" >&9 || exit 1
    fi
    [ -z "$append_line" ] || printf '%s\n' "$append_line" >&9 || exit 1
    if [ -n "$append_source" ]; then
      [ "$append_separator" -eq 0 ] || printf '\n' >&9 || exit 1
      if [ "$append_skip" -eq 0 ]; then
        cat <&6 >&9 || exit 1
      else
        dd bs=1 skip="$append_skip" <&6 >&9 2>/dev/null || exit 1
      fi
    fi
    [ "$(path_file_identity "$source" 2>/dev/null)" = "$source_fd_identity" ] || exit 1
    if [ -n "$append_source" ]; then
      [ "$(path_file_identity "$append_source" 2>/dev/null)" = "$append_fd_identity" ] || exit 1
    fi
    regular_file "$destination" || exit 1
    [ "$(path_file_identity "$destination" 2>/dev/null)" = "$destination_fd_identity" ] || exit 1
    printf '%s' "$destination_fd_identity"
  ) || {
    rm -f -- "$destination"
    return 1
  }
  private_file "$destination" || return 1
  [ "$(path_file_identity "$destination" 2>/dev/null)" = "$destination_identity" ]
}

copy_private_atomic() {
  local source=$1 destination=$2 destination_type=${3:-private} source_type=${4:-private} binding_id=${5:-}
  local append_line=${6:-} append_source=${7:-} append_source_type=${8:-private}
  local append_skip=${9:-0} append_separator=${10:-0}
  local source_dir destination_dir destination_name source_real destination_real tmp rc
  local source_parent source_base source_expected destination_parent destination_base destination_expected tmp_identity
  local append_source_dir append_source_parent append_source_base append_source_expected append_source_real
  source_dir=${source%/*}
  [ -L "$source_dir" ] && return 1
  source_parent=${source_dir%/*}
  source_base=${source_dir##*/}
  source_expected=$(cd -P -- "$source_parent" && pwd -P)/$source_base || return 1
  if [ "$source_dir" = "$STATE" ]; then
    [ -d "$source_dir" ] && [ ! -L "$source_dir" ] || return 1
  else
    private_directory "$source_dir" || return 1
  fi
  source_real=$(cd -P -- "$source_dir" && pwd -P) || return 1
  [ "$source_real" = "$source_expected" ] || return 1
  if [ -n "$append_source" ]; then
    append_source_dir=${append_source%/*}
    [ -L "$append_source_dir" ] && return 1
    append_source_parent=${append_source_dir%/*}
    append_source_base=${append_source_dir##*/}
    append_source_expected=$(cd -P -- "$append_source_parent" && pwd -P)/$append_source_base || return 1
    if [ "$append_source_dir" = "$STATE" ]; then
      [ -d "$append_source_dir" ] && [ ! -L "$append_source_dir" ] || return 1
    else
      private_directory "$append_source_dir" || return 1
    fi
    append_source_real=$(cd -P -- "$append_source_dir" && pwd -P) || return 1
    [ "$append_source_real" = "$append_source_expected" ] || return 1
  fi
  destination_dir=${destination%/*}
  destination_name=${destination##*/}
  [ -L "$destination_dir" ] && return 1
  destination_parent=${destination_dir%/*}
  destination_base=${destination_dir##*/}
  destination_expected=$(cd -P -- "$destination_parent" && pwd -P)/$destination_base || return 1
  if [ "$destination_dir" = "$STATE" ]; then
    [ -d "$destination_dir" ] && [ ! -L "$destination_dir" ] || return 1
  else
    private_directory "$destination_dir" || return 1
  fi
  destination_real=$(cd -P -- "$destination_dir" && pwd -P) || return 1
  [ "$destination_real" = "$destination_expected" ] || return 1
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if [ "$destination_type" = regular ]; then
      regular_file "$destination" || return 1
    else
      private_file "$destination" || return 1
    fi
  fi
  tmp=$(mktemp "$STATE/.endpoint-binding-copy.XXXXXX") || return 1
  rm -f -- "$tmp" || return 1
  if ! copy_to_new_private_file "$source" "$tmp" "$source_type" "$binding_id" \
    "$append_line" "$append_source" "$append_source_type" "$append_skip" "$append_separator"; then
    rm -f -- "$tmp"
    return 1
  fi
  tmp_identity=$(path_file_identity "$tmp" 2>/dev/null) || { rm -f -- "$tmp"; return 1; }
  (
    cd -P -- "$destination_dir" || exit 1
    [ "$(pwd -P)" = "$destination_expected" ] || exit 1
    if [ "$destination_dir" = "$STATE" ]; then
      [ -d . ] && [ ! -L . ] || exit 1
    else
      private_directory . || exit 1
    fi
    if [ -e "./$destination_name" ] || [ -L "./$destination_name" ]; then
      if [ "$destination_type" = regular ]; then
        regular_file "./$destination_name" || exit 1
      else
        private_file "./$destination_name" || exit 1
      fi
    fi
    atomic_rename_nofollow "$tmp" "./$destination_name" || exit 1
    [ "$(pwd -P)" = "$destination_expected" ] || exit 1
    if [ "$destination_type" = regular ]; then
      regular_file "./$destination_name" || exit 1
    else
      private_file "./$destination_name" || exit 1
    fi
    [ "$(path_file_identity "./$destination_name" 2>/dev/null)" = "$tmp_identity" ]
  )
  rc=$?
  [ "$rc" -eq 0 ] || rm -f -- "$tmp"
  return "$rc"
}

append_private_line_atomic() {
  copy_private_atomic "$1" "$1" private private '' "$2"
}

append_private_file_atomic() {
  copy_private_atomic "$1" "$1" private private '' '' "$2" "${3:-private}" "${4:-0}" "${5:-0}"
}

initialize_private_file() {
  local destination=$1 tmp
  tmp=$(mktemp "$STATE/.endpoint-binding-empty.XXXXXX") || return 1
  if ! private_file "$tmp" || ! copy_private_atomic "$tmp" "$destination"; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp" || return 1
}

write_completed_stage() {
  local stage=$1 tmp rc=0
  private_directory "$stage" || return 1
  tmp=$(mktemp "$STATE/.endpoint-binding-completed.XXXXXX") || return 1
  if ! private_file "$tmp" || ! append_private_line_atomic "$tmp" completed \
    || ! copy_private_atomic "$tmp" "$stage/completed"; then
    rc=1
  fi
  rm -f -- "$tmp" || true
  return "$rc"
}

complete_apply_stage() {
  write_completed_stage "$STAGE_DIR" || return 1
  APPLY_COMMITTED=1
}

restore_existing_records() {
  [ -n "$RECORDS_BEFORE" ] || return 1
  copy_private_atomic "$RECORDS_BEFORE" "$RECORDS"
}

remove_stage_directory() {
  local stage=$1 stage_parent stage_base stage_expected path
  [ -L "$stage" ] && return 1
  [ -d "$stage" ] || return 1
  stage_parent=${stage%/*}
  stage_base=${stage##*/}
  stage_expected=$(cd -P -- "$stage_parent" && pwd -P)/$stage_base || return 1
  (
    cd -P -- "$stage" || exit 1
    [ "$(pwd -P)" = "$stage_expected" ] || exit 1
    for path in ./* ./.??*; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      [ "${path##*/}" = completed ] && continue
      rm -f -- "$path" || exit 1
    done
    if [ -e ./completed ] || [ -L ./completed ]; then
      private_file ./completed || exit 1
      rm -f -- ./completed || exit 1
    fi
  ) || return 1
  [ -L "$stage" ] && return 1
  rmdir -- "$stage"
}

cleanup_incomplete_apply_stage() {
  local stage=$1 path base id before after
  local -a ids=()
  private_directory "$stage" || return 1
  for path in "$stage"/*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    base=${path##*/}
    case "$base" in
      report.*|records|evidence) continue ;;
      *.before)
        id=${base%.before}
        valid_task_id "$id" || return 1
        before=$path
        after="$stage/$id.after"
        [ -e "$after" ] || [ -L "$after" ] || continue
        private_file "$before" && private_file "$after" || return 1
        ids+=("$id")
        ;;
      *.after)
        [ -L "$path" ] && return 1
        id=${base%.after}
        valid_task_id "$id" || return 1
        before="$stage/$id.before"
        [ -e "$before" ] || [ -L "$before" ] || continue
        continue
        ;;
      *.rollback)
        id=${base%.rollback}
        valid_task_id "$id" && private_file "$path" || return 1
        ;;
      *) return 1 ;;
    esac
  done
  restore_stage_evidence "$stage" || return 1
  for id in "${ids[@]}"; do
    before="$stage/$id.before"
    after="$stage/$id.after"
    if [ -e "$BACKUP_DIR" ] || [ -L "$BACKUP_DIR" ]; then
      remove_private_backup_files "$BACKUP_DIR/$id.before" "$BACKUP_DIR/$id.after" || return 1
    fi
  done
  if [ -e "$BACKUP_DIR" ] || [ -L "$BACKUP_DIR" ]; then
    directory_empty "$BACKUP_DIR" || return 1
    rmdir -- "$BACKUP_DIR" || return 1
  fi
  remove_stage_directory "$stage"
}

recover_existing_apply_stage() {
  local stage=$1 id before_name after_name extra merged_tmp merged_published=0
  local -a ids=()
  private_directory "$stage" || return 1
  private_file "$RECORDS" || return 1
  private_file "$stage/records" || return 1
  private_file "$stage/records.before" || return 1
  merged_tmp=$(mktemp "$STATE/.endpoint-binding-merge-check.XXXXXX") || return 1
  if ! private_file "$merged_tmp" \
    || ! copy_private_atomic "$stage/records.before" "$merged_tmp" \
    || ! append_private_file_atomic "$merged_tmp" "$stage/records"; then
    rm -f -- "$merged_tmp"
    return 1
  fi
  if cmp -s -- "$RECORDS" "$stage/records.before"; then
    while IFS=$'\t' read -r id before_name after_name extra || [ -n "${id:-}${before_name:-}${after_name:-}${extra:-}" ]; do
      [ -n "${id:-}" ] && [ -z "${extra:-}" ] || {
        rm -f -- "$merged_tmp"
        return 1
      }
      valid_task_id "$id" || {
        rm -f -- "$merged_tmp"
        return 1
      }
      [ "$before_name" = "$id.before" ] && [ "$after_name" = "$id.after" ] || {
        rm -f -- "$merged_tmp"
        return 1
      }
      ids+=("$id")
    done < "$stage/records"
    restore_stage_evidence "$stage" || {
      rm -f -- "$merged_tmp"
      RECOVERY_REQUIRED=1
      return 1
    }
  elif cmp -s -- "$RECORDS" "$merged_tmp"; then
    merged_published=1
    private_directory "$BACKUP_DIR" || {
      rm -f -- "$merged_tmp"
      return 1
    }
    while IFS=$'\t' read -r id before_name after_name extra || [ -n "${id:-}${before_name:-}${after_name:-}${extra:-}" ]; do
      [ -n "${id:-}" ] && [ -z "${extra:-}" ] || {
        rm -f -- "$merged_tmp"
        return 1
      }
      valid_task_id "$id" || {
        rm -f -- "$merged_tmp"
        return 1
      }
      [ "$before_name" = "$id.before" ] && [ "$after_name" = "$id.after" ] || {
        rm -f -- "$merged_tmp"
        return 1
      }
      recorded_id_add "$id"
    done < "$stage/records.before"
    while IFS=$'\t' read -r id before_name after_name extra || [ -n "${id:-}${before_name:-}${after_name:-}${extra:-}" ]; do
      [ -n "${id:-}" ] && [ -z "${extra:-}" ] || {
        rm -f -- "$merged_tmp"
        return 1
      }
      valid_task_id "$id" || {
        rm -f -- "$merged_tmp"
        return 1
      }
      [ "$before_name" = "$id.before" ] && [ "$after_name" = "$id.after" ] || {
        rm -f -- "$merged_tmp"
        return 1
      }
      if ! private_file "$BACKUP_DIR/$before_name" \
        || ! private_file "$BACKUP_DIR/$after_name"; then
        rm -f -- "$merged_tmp"
        return 1
      fi
      ids+=("$id")
      recorded_id_add "$id"
    done < "$stage/records"
    acquire_merge_locks 1 || {
      rm -f -- "$merged_tmp"
      return 1
    }
    revalidate_merge_records 1 || {
      release_merge_locks || true
      rm -f -- "$merged_tmp"
      return 1
    }
    while IFS=$'\t' read -r id before_name after_name extra || [ -n "${id:-}${before_name:-}${after_name:-}${extra:-}" ]; do
      if ! rollback_partial_binding "$STATE/$id.meta" "$id" \
        "$BACKUP_DIR/$before_name" "$BACKUP_DIR/$after_name" "$stage/$id.rollback"; then
        release_merge_locks || true
        rm -f -- "$merged_tmp"
        return 1
      fi
    done < "$stage/records"
    restore_stage_evidence "$stage" || {
      release_merge_locks || true
      rm -f -- "$merged_tmp"
      RECOVERY_REQUIRED=1
      return 1
    }
  else
    rm -f -- "$merged_tmp"
    return 1
  fi
  if [ "$merged_published" -eq 1 ]; then
    copy_private_atomic "$stage/records.before" "$RECORDS" || {
      release_merge_locks || true
      rm -f -- "$merged_tmp"
      return 1
    }
  fi
  if [ -e "$BACKUP_DIR" ] || [ -L "$BACKUP_DIR" ]; then
    private_directory "$BACKUP_DIR" || {
      [ "$merged_published" -eq 1 ] && release_merge_locks || true
      rm -f -- "$merged_tmp"
      return 1
    }
    for id in "${ids[@]}"; do
      remove_private_backup_files "$BACKUP_DIR/$id.before" "$BACKUP_DIR/$id.after" || {
        [ "$merged_published" -eq 1 ] && release_merge_locks || true
        rm -f -- "$merged_tmp"
        return 1
      }
    done
  fi
  rm -f -- "$merged_tmp" || {
    [ "$merged_published" -eq 1 ] && release_merge_locks || true
    return 1
  }
  remove_stage_directory "$stage" || {
    [ "$merged_published" -eq 1 ] && release_merge_locks || true
    return 1
  }
  if [ "$merged_published" -eq 1 ]; then
    release_merge_locks
  fi
}

cleanup_pre_manifest_apply_stage() {
  local stage=$1
  private_directory "$stage" || return 1
  private_file "$RECORDS" || return 1
  private_file "$stage/records" || return 1
  if cmp -s -- "$RECORDS" "$stage/records"; then
    recover_partial_apply_stage "$stage"
  else
    restore_stage_evidence "$stage" || return 1
    remove_stage_directory "$stage"
  fi
}

recover_partial_apply_stage() {
  local stage=$1 id before_name after_name extra meta
  local -a ids=()
  private_directory "$stage" || return 1
  private_file "$RECORDS" || return 1
  private_file "$stage/records" || return 1
  cmp -s -- "$RECORDS" "$stage/records" || return 1
  while IFS=$'\t' read -r id before_name after_name extra || [ -n "${id:-}${before_name:-}${after_name:-}${extra:-}" ]; do
    [ -n "${id:-}" ] && [ -z "${extra:-}" ] || return 1
    valid_task_id "$id" || return 1
    [ "$before_name" = "$id.before" ] && [ "$after_name" = "$id.after" ] || return 1
    private_file "$stage/$before_name" && private_file "$stage/$after_name" || return 1
    meta="$STATE/$id.meta"
    ids+=("$id")
    if ! acquire_meta_lock "$meta"; then
      RECOVERY_REQUIRED=1
      return 1
    fi
    if ! rollback_partial_binding "$meta" "$id" "$stage/$before_name" \
      "$stage/$after_name" "$stage/$id.rollback"; then
      release_meta_lock || true
      RECOVERY_REQUIRED=1
      return 1
    fi
    release_meta_lock || {
      RECOVERY_REQUIRED=1
      return 1
    }
  done < "$stage/records"
  restore_stage_evidence "$stage" || {
    RECOVERY_REQUIRED=1
    return 1
  }
  rm -f -- "$RECORDS" || {
    RECOVERY_REQUIRED=1
    return 1
  }
  if [ -e "$BACKUP_DIR" ] || [ -L "$BACKUP_DIR" ]; then
    private_directory "$BACKUP_DIR" || {
      RECOVERY_REQUIRED=1
      return 1
    }
    for id in "${ids[@]}"; do
      remove_private_backup_files "$BACKUP_DIR/$id.before" "$BACKUP_DIR/$id.after" || {
        RECOVERY_REQUIRED=1
        return 1
      }
    done
    directory_empty "$BACKUP_DIR" || {
      RECOVERY_REQUIRED=1
      return 1
    }
    rmdir -- "$BACKUP_DIR" || {
      RECOVERY_REQUIRED=1
      return 1
    }
  fi
  remove_stage_directory "$stage" || {
    RECOVERY_REQUIRED=1
    return 1
  }
}

recover_apply_stage() {
  local stage
  for stage in "$STATE"/.endpoint-binding-stage.*; do
    [ -L "$stage" ] && return 1
    [ -d "$stage" ] || continue
    private_directory "$stage" || return 1
    if [ -e "$stage/completed" ] || [ -L "$stage/completed" ]; then
      private_file "$stage/completed" || return 1
      remove_completed_stage "$stage" || return 1
      continue
    fi
    if [ -e "$RECORDS" ] || [ -L "$RECORDS" ]; then
      if [ -e "$stage/records.before" ] || [ -L "$stage/records.before" ]; then
        recover_existing_apply_stage "$stage" || return 1
      elif [ -e "$stage/records" ] || [ -L "$stage/records" ]; then
        cleanup_pre_manifest_apply_stage "$stage" || return 1
      else
        restore_stage_evidence "$stage" || return 1
        remove_stage_directory "$stage" || return 1
      fi
      continue
    fi
    cleanup_incomplete_apply_stage "$stage" || return 1
  done
}

abort_apply() {
  local rc=${1:-1}
  local rollback_rc=0 evidence_rc=0 recovery_rc=0
  RECOVERY_REQUIRED=1
  [ "$APPLY_ABORTED" -eq 0 ] || return "$rc"
  APPLY_ABORTED=1
  release_meta_lock || rc=1
  if [ "$APPLY_COMMITTED" -eq 1 ] \
    || { [ -n "$STAGE_DIR" ] && private_file "$STAGE_DIR/completed"; }; then
    APPLY_COMMITTED=1
    RECOVERY_REQUIRED=0
    release_merge_locks || rc=1
    release_apply_locks || rc=1
    return "$rc"
  fi
  if [ "$META_WRITE_STARTED" -eq 1 ] && ! rollback_stamps; then
    rollback_rc=1
    rc=1
  fi
  restore_evidence || evidence_rc=1
  if [ "$rollback_rc" -eq 0 ] && [ "$evidence_rc" -eq 0 ]; then
    if [ "$RECORDS_EXISTING" -eq 1 ]; then
      if restore_existing_records; then
        if ! remove_published_backups; then
          rc=1
          recovery_rc=1
        fi
      else
        rc=1
        recovery_rc=1
      fi
    elif [ "$RECORDS_PUBLISHED" -eq 1 ]; then
      if ! rm -f -- "$RECORDS"; then
        rc=1
        recovery_rc=1
      else
        if ! remove_published_backups; then
          rc=1
          recovery_rc=1
          restore_published_backups || rc=1
          publish_recovery_records || rc=1
        fi
      fi
    else
      if ! remove_published_backups; then
        rc=1
        recovery_rc=1
      fi
    fi
  else
    recovery_rc=1
    if [ "$META_WRITE_STARTED" -eq 1 ] && [ "${#STAMP_IDS[@]}" -gt 0 ]; then
      publish_recovery_records || rc=1
    fi
  fi
  if [ "$rollback_rc" -eq 0 ] && [ "$evidence_rc" -eq 0 ] && [ "$recovery_rc" -eq 0 ]; then
    RECOVERY_REQUIRED=0
  fi
  release_merge_locks || rc=1
  release_apply_locks || rc=1
  return "$rc"
}

handle_signal() {
  trap - HUP INT TERM
  if [ "$UNDO_ACTIVE" -eq 1 ]; then
    abort_undo || true
  else
    abort_apply 1 || true
  fi
  exit 1
}

snapshot_evidence_file() {
  local destination=$1 label=$2 snapshot
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    [ -f "$destination" ] && [ ! -L "$destination" ] || return 1
    snapshot="$STAGE_DIR/$label.before"
    snapshot_regular_atomic "$destination" "$snapshot" || return 1
    case "$label" in
      report) REPORT_BEFORE=$snapshot; REPORT_PRESENT=1; REPORT_SNAPSHOT_READY=1 ;;
      scan-marker) SCAN_MARKER_BEFORE=$snapshot; SCAN_MARKER_PRESENT=1; SCAN_MARKER_SNAPSHOT_READY=1 ;;
      marker) MARKER_BEFORE=$snapshot; MARKER_PRESENT=1; MARKER_SNAPSHOT_READY=1 ;;
      *) return 1 ;;
    esac
  else
    case "$label" in
      report) REPORT_BEFORE=; REPORT_PRESENT=0; REPORT_SNAPSHOT_READY=1 ;;
      scan-marker) SCAN_MARKER_BEFORE=; SCAN_MARKER_PRESENT=0; SCAN_MARKER_SNAPSHOT_READY=1 ;;
      marker) MARKER_BEFORE=; MARKER_PRESENT=0; MARKER_SNAPSHOT_READY=1 ;;
      *) return 1 ;;
    esac
  fi
}

prepare_evidence() {
  local evidence_tmp
  snapshot_evidence_file "$REPORT" report || return 1
  snapshot_evidence_file "$SCAN_MARKER" scan-marker || return 1
  snapshot_evidence_file "$MARKER" marker || return 1
  evidence_tmp=$(mktemp "$STAGE_DIR/report.evidence.XXXXXX") || return 1
  if ! private_file "$evidence_tmp" \
    || ! append_private_line_atomic "$evidence_tmp" $'report\t'"$REPORT_PRESENT" \
    || ! append_private_line_atomic "$evidence_tmp" $'scan-marker\t'"$SCAN_MARKER_PRESENT" \
    || ! append_private_line_atomic "$evidence_tmp" $'marker\t'"$MARKER_PRESENT" \
    || ! copy_private_atomic "$evidence_tmp" "$STAGE_DIR/evidence"; then
    rm -f -- "$evidence_tmp"
    return 1
  fi
  rm -f -- "$evidence_tmp" || return 1
}

restore_evidence_file() {
  local destination=$1 snapshot=$2 present=$3
  if [ "$present" -eq 1 ]; then
    copy_private_atomic "$snapshot" "$destination" regular || return 1
  elif [ -e "$destination" ] || [ -L "$destination" ]; then
    rm -f -- "$destination" || return 1
  fi
}

restore_stage_evidence() {
  local stage=$1 label present extra destination count=0
  local seen_report=0 seen_scan_marker=0 seen_marker=0
  [ -e "$stage/evidence" ] || [ -L "$stage/evidence" ] || return 0
  private_file "$stage/evidence" || return 1
  while IFS=$'\t' read -r label present extra || [ -n "${label:-}${present:-}${extra:-}" ]; do
    [ -n "${label:-}" ] && [ -z "${extra:-}" ] || return 1
    case "$label" in
      report)
        [ "$seen_report" -eq 0 ] || return 1
        seen_report=1
        destination=$REPORT
        ;;
      scan-marker)
        [ "$seen_scan_marker" -eq 0 ] || return 1
        seen_scan_marker=1
        destination=$SCAN_MARKER
        ;;
      marker)
        [ "$seen_marker" -eq 0 ] || return 1
        seen_marker=1
        destination=$MARKER
        ;;
      *) return 1 ;;
    esac
    [ "$present" = 0 ] || [ "$present" = 1 ] || return 1
    if [ "$present" = 1 ]; then
      private_file "$stage/$label.before" || return 1
      restore_evidence_file "$destination" "$stage/$label.before" 1 || return 1
    else
      restore_evidence_file "$destination" '' 0 || return 1
    fi
    count=$((count + 1))
  done < "$stage/evidence"
  [ "$count" -eq 3 ] || return 1
  [ "$seen_report" -eq 1 ] && [ "$seen_scan_marker" -eq 1 ] && [ "$seen_marker" -eq 1 ]
}

restore_evidence() {
  local rc=0
  if [ "$REPORT_SNAPSHOT_READY" -eq 1 ]; then
    if [ "$REPORT_PRESENT" -eq 1 ]; then
      restore_evidence_file "$REPORT" "$REPORT_BEFORE" 1 || rc=1
    else
      restore_evidence_file "$REPORT" '' 0 || rc=1
    fi
  fi
  if [ "$SCAN_MARKER_SNAPSHOT_READY" -eq 1 ]; then
    if [ "$SCAN_MARKER_PRESENT" -eq 1 ]; then
      restore_evidence_file "$SCAN_MARKER" "$SCAN_MARKER_BEFORE" 1 || rc=1
    else
      restore_evidence_file "$SCAN_MARKER" '' 0 || rc=1
    fi
  fi
  if [ "$MARKER_SNAPSHOT_READY" -eq 1 ]; then
    if [ "$MARKER_PRESENT" -eq 1 ]; then
      restore_evidence_file "$MARKER" "$MARKER_BEFORE" 1 || rc=1
    else
      restore_evidence_file "$MARKER" '' 0 || rc=1
    fi
  fi
  return "$rc"
}

publish_recovery_records() {
  local manifest_tmp i
  if [ "$RECORDS_PUBLISHED" -eq 1 ] && private_file "$RECORDS"; then
    return 0
  fi
  if [ -e "$RECORDS" ] || [ -L "$RECORDS" ]; then
    return 1
  fi
  manifest_tmp=$(mktemp "$STATE/.endpoint-binding-recovery-records.XXXXXX") || return 1
  private_file "$manifest_tmp" || { rm -f -- "$manifest_tmp"; return 1; }
  for i in "${!STAMP_IDS[@]}"; do
    [ "${STAMP_SELECTED[$i]:-1}" -eq 1 ] || continue
    append_private_line_atomic "$manifest_tmp" \
      "${STAMP_IDS[$i]}"$'\t'"${STAMP_IDS[$i]}.before"$'\t'"${STAMP_IDS[$i]}.after" || {
      rm -f -- "$manifest_tmp"
      return 1
    }
  done
  RECORDS_PUBLISHED=1
  if ! copy_private_atomic "$manifest_tmp" "$RECORDS"; then
    RECORDS_PUBLISHED=0
    rm -f -- "$manifest_tmp"
    return 1
  fi
  rm -f -- "$manifest_tmp" || true
}

validate_recovery_namespace() {
  local id before_name after_name extra path base
  local -a expected=()
  RECOVERY_NAMESPACE_PRESENT=0
  RECORDED_IDS=()
  if [ -e "$RECORDS" ] || [ -L "$RECORDS" ]; then
    RECOVERY_NAMESPACE_PRESENT=1
    private_file "$RECORDS" || return 1
    private_directory "$BACKUP_DIR" || return 1
    while IFS=$'\t' read -r id before_name after_name extra || [ -n "${id:-}${before_name:-}${after_name:-}${extra:-}" ]; do
      [ -n "${id:-}" ] && [ -z "${extra:-}" ] || return 1
      valid_task_id "$id" || return 1
      [ "$before_name" = "$id.before" ] && [ "$after_name" = "$id.after" ] || return 1
      valid_stamp_evidence "$id" "$BACKUP_DIR/$before_name" "$BACKUP_DIR/$after_name" || return 1
      recorded_id_add "$id"
      expected+=("$before_name" "$after_name")
    done < "$RECORDS"
    for path in "$BACKUP_DIR"/* "$BACKUP_DIR"/.[!.]* "$BACKUP_DIR"/..?*; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      base=${path##*/}
      list_contains "$base" "${expected[@]}" || return 1
    done
  elif [ -e "$BACKUP_DIR" ] || [ -L "$BACKUP_DIR" ]; then
    RECOVERY_NAMESPACE_PRESENT=1
    private_directory "$BACKUP_DIR" || return 1
    return 1
  fi
}

undo_rollback_changed() {
  local index rc=0 meta before after lock_held
  lock_held=$UNDO_LOCKS_HELD
  for ((index=UNDO_CHANGED - 1; index >= 0; index--)); do
    [ "${UNDO_TOUCHED[$index]:-0}" -eq 1 ] || continue
    meta=${UNDO_METAS[$index]}
    before=${UNDO_RECOVERY_BEFORE[$index]:-${UNDO_BEFORE[$index]}}
    after=${UNDO_RECOVERY_AFTER[$index]:-${UNDO_AFTER[$index]}}
    if [ "$lock_held" -eq 0 ] && ! acquire_meta_lock "$meta"; then
      rc=1
      continue
    fi
    if ! regular_file "$meta"; then
      rc=1
      [ "$lock_held" -eq 1 ] || release_meta_lock || rc=1
      continue
    fi
    if cmp -s -- "$meta" "$before"; then
      copy_private_atomic "$after" "$meta" regular || rc=1
    elif ! cmp -s -- "$meta" "$after"; then
      rc=1
    fi
    [ "$lock_held" -eq 1 ] || release_meta_lock || rc=1
  done
  return "$rc"
}

restore_undo_recovery() {
  local i id rc=0
  [ -n "$UNDO_RECOVERY_STAGE" ] || return 0
  [ -L "$UNDO_RECOVERY_STAGE" ] && return 1
  [ -d "$UNDO_RECOVERY_STAGE" ] || return 0
  private_directory "$UNDO_RECOVERY_STAGE" || return 1
  private_file "$UNDO_RECOVERY_STAGE/records" || return 1
  if [ -e "$RECORDS" ] || [ -L "$RECORDS" ]; then
    private_file "$RECORDS" || rc=1
  else
    copy_private_atomic "$UNDO_RECOVERY_STAGE/records" "$RECORDS" || rc=1
  fi
  if [ -e "$BACKUP_DIR" ] || [ -L "$BACKUP_DIR" ]; then
    private_directory "$BACKUP_DIR" || rc=1
  else
    mkdir -- "$BACKUP_DIR" || rc=1
    private_directory "$BACKUP_DIR" || rc=1
  fi
  for i in "${!UNDO_IDS[@]}"; do
    id=${UNDO_IDS[$i]}
    if [ -e "$BACKUP_DIR/$id.before" ] || [ -L "$BACKUP_DIR/$id.before" ]; then
      private_file "$BACKUP_DIR/$id.before" || rc=1
    else
      copy_private_atomic "$UNDO_RECOVERY_STAGE/$id.before" "$BACKUP_DIR/$id.before" || rc=1
    fi
    if [ -e "$BACKUP_DIR/$id.after" ] || [ -L "$BACKUP_DIR/$id.after" ]; then
      private_file "$BACKUP_DIR/$id.after" || rc=1
    else
      copy_private_atomic "$UNDO_RECOVERY_STAGE/$id.after" "$BACKUP_DIR/$id.after" || rc=1
    fi
  done
  return "$rc"
}

abort_undo() {
  local rc=1
  release_meta_lock || rc=1
  if [ "$UNDO_LOCKS_HELD" -eq 0 ] && [ "$UNDO_LOCKS_ACQUIRING" -eq 1 ]; then
    release_undo_locks || rc=1
  fi
  undo_rollback_changed || rc=1
  restore_undo_recovery || rc=1
  release_undo_locks || rc=1
  return "$rc"
}

remove_completed_stage() {
  remove_stage_directory "$1"
}

recover_undo_stage() {
  local stage id before_name after_name extra rc=0 i meta current undone
  local -a ids=() before_names=() after_names=()
  for stage in "$STATE"/.endpoint-binding-undo-cleanup.*; do
    [ -L "$stage" ] && return 1
    [ -d "$stage" ] || continue
    private_directory "$stage" || return 1
    if [ -e "$stage/completed" ] || [ -L "$stage/completed" ]; then
      private_file "$stage/completed" || return 1
      remove_completed_stage "$stage" || return 1
      continue
    fi
    if [ ! -e "$stage/records" ] && [ ! -L "$stage/records" ]; then
      validate_recovery_namespace || return 1
      remove_stage_directory "$stage" || return 1
      continue
    fi
    private_file "$stage/records" || return 1
    ids=()
    before_names=()
    after_names=()
    while IFS=$'\t' read -r id before_name after_name extra || [ -n "${id:-}${before_name:-}${after_name:-}${extra:-}" ]; do
      [ -n "${id:-}" ] && [ -z "${extra:-}" ] || return 1
      valid_task_id "$id" || return 1
      [ "$before_name" = "$id.before" ] && [ "$after_name" = "$id.after" ] || return 1
      private_file "$stage/$before_name" && private_file "$stage/$after_name" || return 1
      ids+=("$id")
      before_names+=("$before_name")
      after_names+=("$after_name")
    done < "$stage/records"
    if [ -e "$RECORDS" ] || [ -L "$RECORDS" ]; then
      if ! private_file "$RECORDS" || ! cmp -s -- "$RECORDS" "$stage/records"; then
        return 1
      fi
    else
      copy_private_atomic "$stage/records" "$RECORDS" || rc=1
    fi
    if [ -e "$BACKUP_DIR" ] || [ -L "$BACKUP_DIR" ]; then
      private_directory "$BACKUP_DIR" || return 1
    else
      mkdir -- "$BACKUP_DIR" || return 1
      private_directory "$BACKUP_DIR" || return 1
    fi
    for i in "${!ids[@]}"; do
      id=${ids[$i]}
      before_name=${before_names[$i]}
      after_name=${after_names[$i]}
      if [ -e "$BACKUP_DIR/$before_name" ] || [ -L "$BACKUP_DIR/$before_name" ]; then
        if ! private_file "$BACKUP_DIR/$before_name" \
          || ! cmp -s -- "$BACKUP_DIR/$before_name" "$stage/$before_name"; then
          rc=1
        fi
      else
        copy_private_atomic "$stage/$before_name" "$BACKUP_DIR/$before_name" || rc=1
      fi
      if [ -e "$BACKUP_DIR/$after_name" ] || [ -L "$BACKUP_DIR/$after_name" ]; then
        if ! private_file "$BACKUP_DIR/$after_name" \
          || ! cmp -s -- "$BACKUP_DIR/$after_name" "$stage/$after_name"; then
          rc=1
        fi
      else
        copy_private_atomic "$stage/$after_name" "$BACKUP_DIR/$after_name" || rc=1
      fi
    done
    [ "$rc" -eq 0 ] || return 1
    UNDO_IDS=("${ids[@]}")
    acquire_undo_locks || return 1
    for id in "${ids[@]}"; do
      current="$stage/$id.current"
      undone="$stage/$id.undone"
      if [ -e "$current" ] || [ -L "$current" ]; then
        if ! private_file "$current" || ! private_file "$undone"; then
          release_undo_locks || true
          return 1
        fi
        meta="$STATE/$id.meta"
        if regular_file "$meta"; then
          if cmp -s -- "$meta" "$current"; then
            :
          elif cmp -s -- "$meta" "$undone"; then
            replace_metadata_from_private "$current" "$meta" || {
              release_undo_locks || true
              return 1
            }
          fi
        fi
      elif [ -e "$undone" ] || [ -L "$undone" ]; then
        private_file "$undone" || {
          release_undo_locks || true
          return 1
        }
      fi
    done
    release_undo_locks || return 1
    remove_stage_directory "$stage" || return 1
  done
  return "$rc"
}
trap handle_signal HUP INT TERM

publish_report() {
  if [ -e "$REPORT" ] || [ -L "$REPORT" ]; then
    [ -f "$REPORT" ] && [ ! -L "$REPORT" ] || return 1
  fi
  copy_private_atomic "$REPORT_TMP" "$REPORT" regular
}

restart_apply_scan() {
  if [ "${1:-0}" -eq 1 ]; then
    abort_apply 1 || true
    [ "$RECOVERY_REQUIRED" -eq 0 ] || return 1
  else
    release_merge_locks || return 1
    release_apply_locks || return 1
  fi
  remove_stage_directory "$STAGE_DIR" || return 1
  STAGE_DIR=
  REPORT_TMP=
  release_migration_lock || return 1
  trap - EXIT HUP INT TERM
  exec "$0"
}

apply_migration() {
  local meta id base binding_count binding validation before after before_final after_final
  local backend target i j duplicate manifest_tmp selected_count stage_records
  local -a metas
  require_session_lock || return 1
  recover_apply_stage || return 1
  STAGE_DIR=$(mktemp -d "$STATE/.endpoint-binding-stage.XXXXXX") || return 1
  private_directory "$STAGE_DIR" || return 1
  REPORT_TMP=$(mktemp "$STAGE_DIR/report.XXXXXX") || return 1
  private_file "$REPORT_TMP" || return 1
  prepare_evidence || return 1
  validate_recovery_namespace || return 1

  shopt -s nullglob dotglob
  metas=("$STATE"/*.meta)
  for meta in "${metas[@]}"; do
    base=${meta##*/}
    id=${base%.meta}
    case "$base" in
      .*)
        record_outcome "record $(reason_one_line "$base"): skipped - hidden metadata record is out of scope"
        SKIPPED_LEGACY=1
        continue
        ;;
    esac
    if [ -L "$meta" ]; then
      record_outcome "task $(reason_one_line "$id"): skipped - metadata record is a symlink; endpoint identity is unverifiable"
      SKIPPED_LEGACY=1
      continue
    fi
    if [ ! -f "$meta" ]; then
      record_outcome "task $(reason_one_line "$id"): skipped - metadata record is not a regular file; endpoint identity is unverifiable"
      SKIPPED_LEGACY=1
      continue
    fi
    if ! valid_task_id "$id"; then
      record_outcome "task $(reason_one_line "$id"): skipped - invalid task id"
      SKIPPED_LEGACY=1
      continue
    fi
    acquire_meta_lock "$meta" || return 1
    if ! regular_file "$meta"; then
      SKIPPED_LEGACY=1
      record_outcome "task $id: skipped - metadata record vanished before verification; endpoint identity is unverifiable"
      release_meta_lock || return 1
      continue
    fi
    if ! cat -- "$meta" >/dev/null 2>&1; then
      SKIPPED_LEGACY=1
      if regular_file "$meta"; then
        record_outcome "task $id: skipped - metadata record is unreadable; endpoint identity is unverifiable"
      else
        record_outcome "task $id: skipped - metadata record vanished before verification; endpoint identity is unverifiable"
      fi
      release_meta_lock || return 1
      continue
    fi
    binding_count=$(grep -c '^endpoint_task_id=' "$meta" 2>/dev/null || true)
    if [ "$binding_count" -gt 0 ]; then
      binding=$(fm_meta_get "$meta" endpoint_task_id)
      if [ "$binding_count" -eq 1 ] && [ "$binding" = "$id" ]; then
        record_outcome "task $id: untouched - endpoint_task_id already present"
      elif [ "$binding_count" -gt 1 ]; then
        SKIPPED_LEGACY=1
        record_outcome "task $id: skipped - existing endpoint_task_id binding is duplicated"
      elif [ -z "$binding" ]; then
        SKIPPED_LEGACY=1
        record_outcome "task $id: skipped - existing endpoint_task_id binding is empty"
      else
        SKIPPED_LEGACY=1
        record_outcome "task $id: skipped - existing endpoint_task_id binding mismatches task identity"
      fi
      release_meta_lock || return 1
      continue
    fi
    if recorded_id_contains "$id"; then
      record_outcome "task $id: skipped - existing recovery record has unexpected metadata state"
      SKIPPED_LEGACY=1
      release_meta_lock || return 1
      continue
    fi
    before="$STAGE_DIR/$id.before"
    after="$STAGE_DIR/$id.after"
    copy_private_atomic "$meta" "$before" private regular || { release_meta_lock || true; return 1; }
    copy_private_atomic "$meta" "$after" private regular "$id" || { release_meta_lock || true; return 1; }
    if ! verify_legacy_endpoint "$after" "$id"; then
      if [ "$REPORT_WRITE_FAILED" -eq 1 ]; then
        release_meta_lock || true
        return 1
      fi
      release_meta_lock || true
      SKIPPED_LEGACY=1
      continue
    fi
    backend=$FM_BACKEND_VALIDATED_BACKEND
    target=$FM_BACKEND_VALIDATED_TARGET
    validation=$(fm_backend_validate_task_endpoint "$after" "$id" 2>&1) || {
      record_outcome "task $id: skipped - staged binding failed shared validation: $(reason_one_line "$validation")"
      if [ "$REPORT_WRITE_FAILED" -eq 1 ]; then
        release_meta_lock || true
        return 1
      fi
      release_meta_lock || true
      SKIPPED_LEGACY=1
      continue
    }
    before_final="$BACKUP_DIR/$id.before"
    after_final="$BACKUP_DIR/$id.after"
    STAMP_IDS+=("$id")
    STAMP_METAS+=("$meta")
    STAMP_BEFORE+=("$before")
    STAMP_AFTER+=("$after")
    STAMP_BACKENDS+=("$backend")
    STAMP_TARGETS+=("$target")
    STAMP_SELECTED+=(1)
    STAMP_BEFORE_FINAL+=("$before_final")
    STAMP_AFTER_FINAL+=("$after_final")
    release_meta_lock || return 1
  done

  for i in "${!STAMP_IDS[@]}"; do
    duplicate=0
    for j in "${!STAMP_IDS[@]}"; do
      [ "$i" = "$j" ] && continue
      if [ "${STAMP_BACKENDS[$i]}" = "${STAMP_BACKENDS[$j]}" ] \
        && [ "${STAMP_TARGETS[$i]}" = "${STAMP_TARGETS[$j]}" ]; then
        duplicate=1
        break
      fi
    done
    if [ "$duplicate" -eq 1 ]; then
      STAMP_SELECTED[i]=0
      SKIPPED_LEGACY=1
      record_outcome "task ${STAMP_IDS[$i]}: skipped - ambiguous live endpoint identity is claimed by multiple legacy records" || return 1
    fi
  done

  [ "$REPORT_WRITE_FAILED" -eq 0 ] || return 1
  acquire_apply_locks || return 1
  for i in "${!STAMP_IDS[@]}"; do
    [ "${STAMP_SELECTED[$i]:-0}" -eq 1 ] || continue
    if ! regular_file "${STAMP_METAS[$i]}" || ! cmp -s -- "${STAMP_METAS[$i]}" "${STAMP_BEFORE[$i]}"; then
      restart_apply_scan
      return $?
    fi
    if ! verify_legacy_endpoint "${STAMP_AFTER[$i]}" "${STAMP_IDS[$i]}"; then
      [ "$REPORT_WRITE_FAILED" -eq 0 ] || return 1
      STAMP_SELECTED[i]=0
      SKIPPED_LEGACY=1
      continue
    fi
    record_outcome "task ${STAMP_IDS[$i]}: stamped - exact live endpoint identity verified" || return 1
  done
  stage_records="$STAGE_DIR/records"
  initialize_private_file "$stage_records" || return 1
  for i in "${!STAMP_IDS[@]}"; do
    [ "${STAMP_SELECTED[$i]:-0}" -eq 1 ] || continue
    append_private_line_atomic "$stage_records" \
      "${STAMP_IDS[$i]}"$'\t'"${STAMP_IDS[$i]}.before"$'\t'"${STAMP_IDS[$i]}.after" || return 1
  done
  selected_count=0
  for i in "${!STAMP_IDS[@]}"; do
    [ "${STAMP_SELECTED[$i]:-0}" -eq 1 ] && selected_count=$((selected_count + 1))
  done
  [ "$REPORT_WRITE_FAILED" -eq 0 ] || return 1
  validate_recovery_namespace || return 1
  if [ "$selected_count" -eq 0 ]; then
    if [ "$RECOVERY_NAMESPACE_PRESENT" -eq 1 ]; then
      acquire_merge_locks || return 1
      revalidate_merge_records || {
        release_merge_locks || true
        return 1
      }
    fi
    require_session_lock || return 1
    publish_report || return 1
    write_marker "$SCAN_MARKER" fm-endpoint-binding-migration-scan-v1 || return 1
    if [ "$SKIPPED_LEGACY" -eq 0 ]; then
      write_marker "$MARKER" fm-endpoint-binding-migration-v1 || return 1
    else
      restore_evidence_file "$MARKER" '' 0 || return 1
    fi
    complete_apply_stage || return 1
    release_merge_locks || return 1
    release_apply_locks || return 1
    printf 'ENDPOINT_BINDING_MIGRATION: scanned %s record(s); stamped 0\n' "$OUTCOME_COUNT"
    cat "$REPORT"
    return 0
  fi

  if [ "$RECOVERY_NAMESPACE_PRESENT" -eq 1 ]; then
    RECORDS_EXISTING=1
    RECORDS_BEFORE="$STAGE_DIR/records.before"
    if ! copy_private_atomic "$RECORDS" "$RECORDS_BEFORE"; then
      RECORDS_BEFORE=
      return 1
    fi
  fi
  for i in "${!STAMP_IDS[@]}"; do
    [ "${STAMP_SELECTED[$i]:-0}" -eq 1 ] || continue
    if [ -e "${STAMP_BEFORE_FINAL[$i]}" ] || [ -L "${STAMP_BEFORE_FINAL[$i]}" ] \
      || [ -e "${STAMP_AFTER_FINAL[$i]}" ] || [ -L "${STAMP_AFTER_FINAL[$i]}" ]; then
      return 1
    fi
  done
  if [ -e "$BACKUP_DIR" ] || [ -L "$BACKUP_DIR" ]; then
    private_directory "$BACKUP_DIR" || return 1
    [ "$RECORDS_EXISTING" -eq 1 ] || directory_empty "$BACKUP_DIR" || return 1
  else
    mkdir -- "$BACKUP_DIR" || return 1
    BACKUP_DIR_CREATED=1
    if ! private_directory "$BACKUP_DIR"; then
      remove_published_backups
      return 1
    fi
  fi
  acquire_merge_locks || { abort_apply 1; return $?; }
  revalidate_merge_records || { abort_apply 1; return $?; }
  for i in "${!STAMP_IDS[@]}"; do
    [ "${STAMP_SELECTED[$i]:-0}" -eq 1 ] || continue
    copy_private_atomic "${STAMP_BEFORE[$i]}" "${STAMP_BEFORE_FINAL[$i]}" || { abort_apply 1; return $?; }
    copy_private_atomic "${STAMP_AFTER[$i]}" "${STAMP_AFTER_FINAL[$i]}" || { abort_apply 1; return $?; }
  done

  manifest_tmp=$(mktemp "$STATE/.endpoint-binding-records.XXXXXX") || { abort_apply 1; return $?; }
  private_file "$manifest_tmp" || { rm -f -- "$manifest_tmp"; abort_apply 1; return $?; }
  if [ "$RECORDS_EXISTING" -eq 1 ]; then
    copy_private_atomic "$RECORDS" "$manifest_tmp" || {
      rm -f -- "$manifest_tmp"
      abort_apply 1
      return $?
    }
  fi
  for i in "${!STAMP_IDS[@]}"; do
    [ "${STAMP_SELECTED[$i]:-0}" -eq 1 ] || continue
    append_private_line_atomic "$manifest_tmp" \
      "${STAMP_IDS[$i]}"$'\t'"${STAMP_IDS[$i]}.before"$'\t'"${STAMP_IDS[$i]}.after" || {
      rm -f -- "$manifest_tmp"
      abort_apply 1
      return $?
    }
  done
  RECORDS_PUBLISHED=1
  if ! copy_private_atomic "$manifest_tmp" "$RECORDS"; then
    rm -f -- "$manifest_tmp"
    abort_apply 1
    return $?
  fi
  rm -f -- "$manifest_tmp" || true

  META_WRITE_STARTED=1
  for i in "${!STAMP_IDS[@]}"; do
    [ "${STAMP_SELECTED[$i]:-0}" -eq 1 ] || continue
    if ! regular_file "${STAMP_METAS[$i]}" || ! cmp -s -- "${STAMP_METAS[$i]}" "${STAMP_BEFORE[$i]}"; then
      abort_apply 1
      return $?
    fi
    if ! verify_legacy_endpoint "${STAMP_AFTER[$i]}" "${STAMP_IDS[$i]}"; then
      if [ "$REPORT_WRITE_FAILED" -eq 1 ]; then
        abort_apply 1
        return $?
      fi
      restart_apply_scan 1
      return $?
    fi
    require_session_lock || { abort_apply 1; return $?; }
    if ! copy_private_atomic "${STAMP_AFTER[$i]}" "${STAMP_METAS[$i]}" regular; then
      abort_apply 1
      return $?
    fi
  done

  require_session_lock || { abort_apply 1; return $?; }
  if ! publish_report; then abort_apply 1; return $?; fi
  if ! write_marker "$SCAN_MARKER" fm-endpoint-binding-migration-scan-v1; then abort_apply 1; return $?; fi
  if [ "$SKIPPED_LEGACY" -eq 0 ]; then
    if ! write_marker "$MARKER" fm-endpoint-binding-migration-v1; then abort_apply 1; return $?; fi
  else
    if ! restore_evidence_file "$MARKER" '' 0; then abort_apply 1; return $?; fi
  fi
  if ! complete_apply_stage; then abort_apply 1; return $?; fi
  release_merge_locks || return 1
  release_apply_locks || return 1
  printf 'ENDPOINT_BINDING_MIGRATION: scanned %s record(s); stamped %s\n' "$OUTCOME_COUNT" "$selected_count"
  cat "$REPORT"
}

snapshot_regular_atomic() {
  local source=$1 destination=$2
  regular_file "$source" || return 1
  copy_private_atomic "$source" "$destination" private regular
}

surgical_remove_binding() {
  local meta=$1 id=$2 before=$3 after=$4 output=$5 binding binding_count
  local current_size after_size tmp current last_byte separator=0
  SURGICAL_UNDO_CHANGED=0
  regular_file "$meta" || return 0
  current=$(mktemp "$STATE/.endpoint-binding-surgical-current.XXXXXX") || return 1
  if ! copy_private_atomic "$meta" "$current" private regular; then
    rm -f -- "$current"
    return 1
  fi
  binding="endpoint_task_id=$id"
  binding_count=$(awk -v expected="$binding" '$0 == expected { count++ } END { print count + 0 }' "$current") \
    || { rm -f -- "$current"; return 1; }
  [ "$binding_count" -eq 1 ] || { rm -f -- "$current"; return 0; }
  current_size=$(wc -c < "$current") || { rm -f -- "$current"; return 1; }
  after_size=$(wc -c < "$after") || { rm -f -- "$current"; return 1; }
  [ "$current_size" -ge "$after_size" ] || { rm -f -- "$current"; return 0; }
  dd if="$current" bs=1 count="$after_size" 2>/dev/null | cmp -s -- - "$after" \
    || { rm -f -- "$current"; return 0; }
  tmp=$(mktemp "$STATE/.endpoint-binding-surgical-undo.XXXXXX") \
    || { rm -f -- "$current"; return 1; }
  if ! copy_private_atomic "$before" "$tmp"; then
    rm -f -- "$tmp" "$current"
    return 1
  fi
  if [ "$current_size" -gt "$after_size" ]; then
    if [ -s "$before" ]; then
      last_byte=$(tail -c 1 "$before") || { rm -f -- "$tmp" "$current"; return 1; }
      [ -z "$last_byte" ] || separator=1
    fi
    if ! append_private_file_atomic "$tmp" "$current" private "$after_size" "$separator"; then
      rm -f -- "$tmp" "$current"
      return 1
    fi
  fi
  if ! copy_private_atomic "$tmp" "$output"; then
    rm -f -- "$tmp" "$current"
    return 1
  fi
  rm -f -- "$tmp" "$current" || true
  SURGICAL_UNDO_CHANGED=1
}

replace_metadata_from_private() {
  local source=$1 meta=$2
  private_file "$source" && regular_file "$meta" || return 1
  copy_private_atomic "$source" "$meta" regular
}

rollback_partial_binding() {
  local meta=$1 id=$2 before=$3 after=$4 output=$5
  if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
    return 0
  fi
  regular_file "$meta" || return 0
  cmp -s -- "$meta" "$before" && return 0
  surgical_remove_binding "$meta" "$id" "$before" "$after" "$output" || return 1
  [ "$SURGICAL_UNDO_CHANGED" -eq 1 ] || return 0
  replace_metadata_from_private "$output" "$meta"
}

undo_migration() {
  local id before_name after_name meta before after i extra cleanup_stage cleanup_rc
  local current_snapshot undone_snapshot removed_count=0
  UNDO_IDS=()
  UNDO_METAS=()
  UNDO_BEFORE=()
  UNDO_AFTER=()
  UNDO_TOUCHED=()
  UNDO_CHANGED=0
  UNDO_RECOVERY_AFTER=()
  UNDO_RECOVERY_BEFORE=()
  UNDO_RECOVERY_STAGE=
  if [ ! -e "$RECORDS" ] && [ ! -L "$RECORDS" ]; then
    echo "ENDPOINT_BINDING_MIGRATION: no recorded stamps to undo"
    return 0
  fi
  private_file "$RECORDS" || return 1
  private_directory "$BACKUP_DIR" || return 1
  while IFS=$'\t' read -r id before_name after_name extra || [ -n "${id:-}${before_name:-}${after_name:-}${extra:-}" ]; do
    [ -n "${id:-}" ] && [ -z "${extra:-}" ] || return 1
    valid_task_id "$id" || return 1
    [ "$before_name" = "$id.before" ] && [ "$after_name" = "$id.after" ] || return 1
    meta="$STATE/$id.meta"
    before="$BACKUP_DIR/$before_name"
    after="$BACKUP_DIR/$after_name"
    valid_stamp_evidence "$id" "$before" "$after" || return 1
    UNDO_IDS+=("$id")
    UNDO_METAS+=("$meta")
    UNDO_BEFORE+=("$before")
    UNDO_AFTER+=("$after")
  done < "$RECORDS"

  UNDO_ACTIVE=1
  acquire_undo_locks || { abort_undo; return $?; }
  cleanup_stage=$(mktemp -d "$STATE/.endpoint-binding-undo-cleanup.XXXXXX") || {
    abort_undo
    return 1
  }
  UNDO_RECOVERY_STAGE=$cleanup_stage
  if ! private_directory "$cleanup_stage"; then
    abort_undo
    return 1
  fi
  for id in "${UNDO_IDS[@]}"; do
    if ! copy_private_atomic "$BACKUP_DIR/$id.before" "$cleanup_stage/$id.before" \
      || ! copy_private_atomic "$BACKUP_DIR/$id.after" "$cleanup_stage/$id.after"; then
      abort_undo
      return 1
    fi
  done
  copy_private_atomic "$RECORDS" "$cleanup_stage/records" || { abort_undo; return 1; }
  for i in "${!UNDO_IDS[@]}"; do
    meta=${UNDO_METAS[$i]}
    if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
      continue
    fi
    regular_file "$meta" || continue
    undone_snapshot="$cleanup_stage/${UNDO_IDS[$i]}.undone"
    surgical_remove_binding "$meta" "${UNDO_IDS[$i]}" "${UNDO_BEFORE[$i]}" \
      "${UNDO_AFTER[$i]}" "$undone_snapshot" || { abort_undo; return $?; }
    [ "$SURGICAL_UNDO_CHANGED" -eq 1 ] || continue
    current_snapshot="$cleanup_stage/${UNDO_IDS[$i]}.current"
    snapshot_regular_atomic "$meta" "$current_snapshot" || { abort_undo; return $?; }
    UNDO_RECOVERY_BEFORE[i]=$undone_snapshot
    UNDO_RECOVERY_AFTER[i]=$current_snapshot
    UNDO_CHANGED=$((i + 1))
    UNDO_TOUCHED[i]=1
    require_session_lock || { abort_undo; return $?; }
    if ! copy_private_atomic "$undone_snapshot" "$meta" regular; then
      abort_undo
      return $?
    fi
    removed_count=$((removed_count + 1))
  done
  require_session_lock || { abort_undo; return $?; }
  cleanup_rc=0
  rm -f -- "$SCAN_MARKER" || cleanup_rc=1
  [ "$cleanup_rc" -eq 0 ] && rm -f -- "$MARKER" || cleanup_rc=1
  if [ "$cleanup_rc" -eq 0 ]; then
    for id in "${UNDO_IDS[@]}"; do
      remove_private_backup_files "$BACKUP_DIR/$id.before" "$BACKUP_DIR/$id.after" || {
        cleanup_rc=1
        break
      }
    done
  fi
  if [ "$cleanup_rc" -eq 0 ]; then
    private_directory "$BACKUP_DIR" || cleanup_rc=1
    [ "$cleanup_rc" -ne 0 ] || rmdir -- "$BACKUP_DIR" 2>/dev/null || cleanup_rc=1
  fi
  [ "$cleanup_rc" -eq 0 ] && rm -f -- "$RECORDS" || cleanup_rc=1
  if [ "$cleanup_rc" -ne 0 ]; then
    if restore_undo_recovery; then
      if remove_stage_directory "$cleanup_stage"; then
        UNDO_RECOVERY_STAGE=
      else
        release_undo_locks || true
        echo "ENDPOINT_BINDING_MIGRATION: undo cleanup failed; recovery staging was retained" >&2
        return 1
      fi
    else
      release_undo_locks || true
      echo "ENDPOINT_BINDING_MIGRATION: undo cleanup failed; recovery staging was retained" >&2
      return 1
    fi
    release_undo_locks || true
    echo "ENDPOINT_BINDING_MIGRATION: undo changed metadata but cleanup failed; migration evidence was retained" >&2
    return 1
  fi
  if ! write_completed_stage "$cleanup_stage"; then
    abort_undo
    return 1
  fi
  UNDO_ACTIVE=0
  UNDO_RECOVERY_STAGE=
  release_undo_locks || return 1
  if ! remove_completed_stage "$cleanup_stage"; then
    echo "ENDPOINT_BINDING_MIGRATION: undo completed but recovery staging cleanup failed" >&2
    return 1
  fi
  printf 'ENDPOINT_BINDING_MIGRATION: undid %s stamp(s)\n' "$removed_count"
}

MIGRATION_LOCK_HELD=1
if ! fm_lock_acquire_wait "$MIGRATION_LOCK"; then
  echo "ENDPOINT_BINDING_MIGRATION: migration transaction lock is unavailable" >&2
  exit 1
fi
require_session_lock || exit 1

recover_undo_stage || {
  echo "ENDPOINT_BINDING_MIGRATION: incomplete undo recovery failed" >&2
  exit 1
}
recover_apply_stage || {
  echo "ENDPOINT_BINDING_MIGRATION: incomplete apply recovery failed" >&2
  exit 1
}

if [ "$MODE" = undo ]; then
  require_session_lock || exit 1
  undo_migration
else
  apply_rc=0
  apply_migration || apply_rc=$?
  if [ "$apply_rc" -ne 0 ]; then
    if [ "$APPLY_ABORTED" -eq 0 ]; then
      abort_apply "$apply_rc" || apply_rc=$?
    fi
    exit "$apply_rc"
  fi
fi
