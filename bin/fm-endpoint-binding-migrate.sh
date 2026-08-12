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
fm_session_lock_owned_by_self "$STATE" || {
  echo "ENDPOINT_BINDING_MIGRATION: session lock is not owned by this session; migration did not run" >&2
  exit 1
}
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

write_marker() {
  local destination=$1 value=$2 tmp
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    [ -f "$destination" ] && [ ! -L "$destination" ] || return 1
  fi
  tmp=$(mktemp "$STATE/.endpoint-binding-marker.XXXXXX") || return 1
  if ! printf '%s\n' "$value" > "$tmp" || ! chmod 0600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$destination"; then
    rm -f -- "$tmp"
    return 1
  fi
}

record_outcome() {
  if ! printf '%s\n' "$1" >> "$REPORT_TMP"; then
    REPORT_WRITE_FAILED=1
    return 1
  fi
  OUTCOME_COUNT=$((OUTCOME_COUNT + 1))
}

reason_one_line() {
  local value=$1
  value=${value//$'\n'/; }
  value=${value//$'\r'/; }
  printf '%s' "${value:-endpoint identity verification refused}"
}

verify_legacy_endpoint() {
  local meta=$1 id=$2 validation_file backend target state reason
  validation_file=$(mktemp "$STATE/.endpoint-binding-verify.XXXXXX") || {
    record_outcome "task $id: skipped - endpoint identity verification could not start"
    return 1
  }
  if ! fm_backend_validate_task_endpoint "$meta" "$id" >"$validation_file" 2>&1; then
    reason=$(reason_one_line "$(cat "$validation_file")")
    rm -f -- "$validation_file"
    record_outcome "task $id: skipped - identity mismatch: $reason"
    return 1
  fi
  rm -f -- "$validation_file"
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
  case "$state" in
    alive)
      return 0
      ;;
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

STAGE_DIR=
REPORT_TMP=
STAMP_IDS=()
STAMP_METAS=()
STAMP_BEFORE=()
STAMP_AFTER=()
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
declare -A RECORDED_IDS=()
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
MERGE_LOCKS_HELD=0
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
    UNDO_LOCK_ACQUIRED[$i]=1
    if ! fm_lock_acquire_wait "${UNDO_LOCK_PATHS[$i]}"; then
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
      UNDO_LOCK_ACQUIRED[$i]=0
    fi
  done
  UNDO_LOCKS_HELD=0
  UNDO_LOCKS_ACQUIRING=0
  return "$rc"
}

acquire_apply_locks() {
  local id path i
  APPLY_LOCK_IDS=($(printf '%s\n' "${STAMP_IDS[@]}" | sort -u))
  APPLY_LOCK_PATHS=()
  APPLY_LOCK_ACQUIRED=()
  for id in "${APPLY_LOCK_IDS[@]}"; do
    path=$(fm_meta_lock_path "$STATE/$id.meta") || return 1
    APPLY_LOCK_PATHS+=("$path")
    APPLY_LOCK_ACQUIRED+=(0)
  done
  for i in "${!APPLY_LOCK_PATHS[@]}"; do
    APPLY_LOCK_ACQUIRED[$i]=1
    if ! fm_lock_acquire_wait "${APPLY_LOCK_PATHS[$i]}"; then
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
      APPLY_LOCK_ACQUIRED[$i]=0
    fi
  done
  APPLY_LOCKS_HELD=0
  return "$rc"
}

acquire_merge_locks() {
  local id path i
  [ "$RECORDS_EXISTING" -eq 1 ] || [ "$RECOVERY_NAMESPACE_PRESENT" -eq 1 ] || [ "${1:-0}" -eq 1 ] || return 0
  MERGE_LOCK_IDS=($(printf '%s\n' "${!RECORDED_IDS[@]}" | sort -u))
  MERGE_LOCK_PATHS=()
  MERGE_LOCK_ACQUIRED=()
  for id in "${MERGE_LOCK_IDS[@]}"; do
    path=$(fm_meta_lock_path "$STATE/$id.meta") || return 1
    MERGE_LOCK_PATHS+=("$path")
    MERGE_LOCK_ACQUIRED+=(0)
  done
  for i in "${!MERGE_LOCK_PATHS[@]}"; do
    MERGE_LOCK_ACQUIRED[$i]=1
    if ! fm_lock_acquire_wait "${MERGE_LOCK_PATHS[$i]}"; then
      release_merge_locks
      return 1
    fi
  done
  MERGE_LOCKS_HELD=1
}

release_merge_locks() {
  local i rc=0
  for ((i=${#MERGE_LOCK_PATHS[@]} - 1; i >= 0; i--)); do
    if [ "${MERGE_LOCK_ACQUIRED[$i]:-0}" -eq 1 ]; then
      fm_lock_release "${MERGE_LOCK_PATHS[$i]}" || rc=1
      MERGE_LOCK_ACQUIRED[$i]=0
    fi
  done
  MERGE_LOCKS_HELD=0
  return "$rc"
}

valid_stamp_evidence() {
  local id=$1 before=$2 after=$3 expected last_byte
  private_file "$before" && private_file "$after" || return 1
  ! grep -q '^endpoint_task_id=' "$before" || return 1
  expected=$(mktemp "$STATE/.endpoint-binding-evidence-check.XXXXXX") || return 1
  if ! copy_private_atomic "$before" "$expected"; then
    rm -f -- "$expected"
    return 1
  fi
  if [ -s "$expected" ]; then
    last_byte=$(tail -c 1 "$expected") || { rm -f -- "$expected"; return 1; }
    [ -z "$last_byte" ] || printf '\n' >> "$expected" || { rm -f -- "$expected"; return 1; }
  fi
  printf 'endpoint_task_id=%s\n' "$id" >> "$expected" || { rm -f -- "$expected"; return 1; }
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
  local i tmp rc=0 meta lock_held
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
    tmp=$(mktemp "$STATE/.endpoint-binding-rollback.XXXXXX") || {
      rc=1
      [ "$lock_held" -eq 1 ] || release_meta_lock || rc=1
      continue
    }
    if ! cp -p -- "${STAMP_BEFORE[$i]}" "$tmp" || ! mv -f -- "$tmp" "${STAMP_METAS[$i]}"; then
      rm -f -- "$tmp"
      rc=1
    fi
    [ "$lock_held" -eq 1 ] || release_meta_lock || rc=1
  done
  return "$rc"
}

remove_published_backups() {
  local i rc=0
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

copy_private_atomic() {
  local source=$1 destination=$2 source_dir source_name destination_dir destination_name
  local source_real destination_real tmp rc source_parent source_base source_expected
  local destination_parent destination_base destination_expected
  source_dir=${source%/*}
  source_name=${source##*/}
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
    private_file "$destination" || return 1
  fi
  tmp=$(mktemp "$STATE/.endpoint-binding-copy.XXXXXX") || return 1
  if ! (
    cd -P -- "$source_dir" || exit 1
    [ "$(pwd -P)" = "$source_expected" ] || exit 1
    if [ "$source_dir" = "$STATE" ]; then
      [ -d . ] && [ ! -L . ] || exit 1
    else
      private_directory . || exit 1
    fi
    private_file "./$source_name" || exit 1
    cp -pP -- "./$source_name" "$tmp" || exit 1
    [ -f "$tmp" ] && [ ! -L "$tmp" ] || exit 1
  ) || ! chmod 0600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  (
    cd -P -- "$destination_dir" || exit 1
    [ "$(pwd -P)" = "$destination_expected" ] || exit 1
    if [ "$destination_dir" = "$STATE" ]; then
      [ -d . ] && [ ! -L . ] || exit 1
    else
      private_directory . || exit 1
    fi
    if [ -e "./$destination_name" ] || [ -L "./$destination_name" ]; then
      private_file "./$destination_name" || exit 1
    fi
    mv -f -- "$tmp" "./$destination_name"
  )
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f -- "$tmp"
  fi
  return "$rc"
}

write_completed_stage() {
  local stage=$1 tmp rc=0
  private_directory "$stage" || return 1
  tmp=$(mktemp "$STATE/.endpoint-binding-completed.XXXXXX") || return 1
  if ! printf 'completed\n' > "$tmp" || ! chmod 0600 "$tmp" \
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
  if ! cat "$stage/records.before" "$stage/records" > "$merged_tmp" || ! chmod 0600 "$merged_tmp"; then
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
      RECORDED_IDS["$id"]=1
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
      private_file "$BACKUP_DIR/$before_name" && private_file "$BACKUP_DIR/$after_name" || {
        rm -f -- "$merged_tmp"
        return 1
      }
      ids+=("$id")
      RECORDED_IDS["$id"]=1
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
  local rollback_rc=0 evidence_rc=0
  [ "$APPLY_ABORTED" -eq 0 ] || return "$rc"
  APPLY_ABORTED=1
  release_meta_lock || rc=1
  if [ "$APPLY_COMMITTED" -eq 1 ] \
    || { [ -n "$STAGE_DIR" ] && private_file "$STAGE_DIR/completed"; }; then
    APPLY_COMMITTED=1
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
      if remove_published_backups; then
        restore_existing_records || {
          rc=1
          RECOVERY_REQUIRED=1
        }
      else
        rc=1
        RECOVERY_REQUIRED=1
      fi
    elif [ "$RECORDS_PUBLISHED" -eq 1 ]; then
      if ! rm -f -- "$RECORDS"; then
        rc=1
        RECOVERY_REQUIRED=1
      else
        if ! remove_published_backups; then
          rc=1
          RECOVERY_REQUIRED=1
          restore_published_backups || rc=1
          publish_recovery_records || rc=1
        fi
      fi
    else
      if ! remove_published_backups; then
        rc=1
        RECOVERY_REQUIRED=1
      fi
    fi
  else
    RECOVERY_REQUIRED=1
    if [ "$META_WRITE_STARTED" -eq 1 ] && [ "${#STAMP_IDS[@]}" -gt 0 ]; then
      publish_recovery_records || rc=1
    fi
  fi
  release_merge_locks || rc=1
  release_apply_locks || rc=1
  return "$rc"
}

handle_signal() {
  trap - HUP INT TERM
  if [ "$MODE" = undo ]; then
    if [ "$UNDO_ACTIVE" -eq 1 ]; then
      abort_undo || true
    else
      release_undo_locks || true
    fi
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
    cp -p -- "$destination" "$snapshot" || return 1
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
  if ! {
    printf 'report\t%s\n' "$REPORT_PRESENT"
    printf 'scan-marker\t%s\n' "$SCAN_MARKER_PRESENT"
    printf 'marker\t%s\n' "$MARKER_PRESENT"
  } > "$evidence_tmp" || ! chmod 0600 "$evidence_tmp" || ! mv -f -- "$evidence_tmp" "$STAGE_DIR/evidence"; then
    rm -f -- "$evidence_tmp"
    return 1
  fi
}

restore_evidence_file() {
  local destination=$1 snapshot=$2 present=$3 tmp
  if [ "$present" -eq 1 ]; then
    tmp=$(mktemp "$STATE/.endpoint-binding-evidence-restore.XXXXXX") || return 1
    if ! cp -p -- "$snapshot" "$tmp" || ! mv -f -- "$tmp" "$destination"; then
      rm -f -- "$tmp"
      return 1
    fi
  elif [ -e "$destination" ] || [ -L "$destination" ]; then
    rm -f -- "$destination" || return 1
  fi
}

restore_stage_evidence() {
  local stage=$1 label present extra destination count=0
  local -A seen=()
  [ -e "$stage/evidence" ] || [ -L "$stage/evidence" ] || return 0
  private_file "$stage/evidence" || return 1
  while IFS=$'\t' read -r label present extra || [ -n "${label:-}${present:-}${extra:-}" ]; do
    [ -n "${label:-}" ] && [ -z "${extra:-}" ] || return 1
    [ "${seen[$label]:-0}" -eq 0 ] || return 1
    case "$label" in
      report) destination=$REPORT ;;
      scan-marker) destination=$SCAN_MARKER ;;
      marker) destination=$MARKER ;;
      *) return 1 ;;
    esac
    [ "$present" = 0 ] || [ "$present" = 1 ] || return 1
    if [ "$present" = 1 ]; then
      private_file "$stage/$label.before" || return 1
      restore_evidence_file "$destination" "$stage/$label.before" 1 || return 1
    else
      restore_evidence_file "$destination" '' 0 || return 1
    fi
    seen[$label]=1
    count=$((count + 1))
  done < "$stage/evidence"
  [ "$count" -eq 3 ] || return 1
  [ "${seen[report]:-0}" -eq 1 ] &&
    [ "${seen[scan-marker]:-0}" -eq 1 ] &&
    [ "${seen[marker]:-0}" -eq 1 ]
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
  for i in "${!STAMP_IDS[@]}"; do
    [ "${STAMP_SELECTED[$i]:-1}" -eq 1 ] || continue
    printf '%s\t%s\t%s\n' "${STAMP_IDS[$i]}" "${STAMP_IDS[$i]}.before" "${STAMP_IDS[$i]}.after" >> "$manifest_tmp" || {
      rm -f -- "$manifest_tmp"
      return 1
    }
  done
  chmod 0600 "$manifest_tmp" || { rm -f -- "$manifest_tmp"; return 1; }
  if ! mv -f -- "$manifest_tmp" "$RECORDS"; then
    rm -f -- "$manifest_tmp"
    return 1
  fi
  RECORDS_PUBLISHED=1
}

validate_recovery_namespace() {
  local id before_name after_name extra path base
  local -A expected=()
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
      RECORDED_IDS[$id]=1
      expected[$before_name]=1
      expected[$after_name]=1
    done < "$RECORDS"
    for path in "$BACKUP_DIR"/* "$BACKUP_DIR"/.[!.]* "$BACKUP_DIR"/..?*; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      base=${path##*/}
      [ "${expected[$base]:-0}" -eq 1 ] || return 1
    done
  elif [ -e "$BACKUP_DIR" ] || [ -L "$BACKUP_DIR" ]; then
    RECOVERY_NAMESPACE_PRESENT=1
    private_directory "$BACKUP_DIR" || return 1
    return 1
  fi
}

undo_rollback_changed() {
  local index tmp rc=0 meta before after lock_held
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
      tmp=$(mktemp "$STATE/.endpoint-binding-undo-rollback.XXXXXX") || {
        rc=1
        [ "$lock_held" -eq 1 ] || release_meta_lock || rc=1
        continue
      }
      if ! cp -p -- "$after" "$tmp" \
        || ! mv -f -- "$tmp" "$meta"; then
        rm -f -- "$tmp"
        rc=1
      fi
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
    chmod 0700 "$BACKUP_DIR" 2>/dev/null || rc=1
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
      chmod 0700 "$BACKUP_DIR" 2>/dev/null || return 1
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
  local tmp
  if [ -e "$REPORT" ] || [ -L "$REPORT" ]; then
    [ -f "$REPORT" ] && [ ! -L "$REPORT" ] || return 1
  fi
  tmp=$(mktemp "$STATE/.endpoint-binding-report.XXXXXX") || return 1
  if ! cp -p -- "$REPORT_TMP" "$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$REPORT"; then
    rm -f -- "$tmp"
    return 1
  fi
}

apply_migration() {
  local meta id base binding_count binding validation before after before_final after_final last_byte
  local i tmp manifest_tmp selected_count stage_records records_before_tmp
  local -a metas
  recover_apply_stage || return 1
  STAGE_DIR=$(mktemp -d "$STATE/.endpoint-binding-stage.XXXXXX") || return 1
  chmod 0700 "$STAGE_DIR" || return 1
  REPORT_TMP=$(mktemp "$STAGE_DIR/report.XXXXXX") || return 1
  chmod 0600 "$REPORT_TMP" || return 1
  prepare_evidence || return 1
  validate_recovery_namespace || return 1

  shopt -s nullglob dotglob
  metas=("$STATE"/*.meta)
  for meta in "${metas[@]}"; do
    base=${meta##*/}
    id=${base%.meta}
    case "$base" in
      .*)
        record_outcome "record $base: skipped - hidden metadata record is out of scope"
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
      continue
    fi
    if [ "${RECORDED_IDS[$id]:-0}" -eq 1 ]; then
      record_outcome "task $id: skipped - existing recovery record has unexpected metadata state"
      SKIPPED_LEGACY=1
      continue
    fi
    acquire_meta_lock "$meta" || return 1
    if ! verify_legacy_endpoint "$meta" "$id"; then
      if [ "$REPORT_WRITE_FAILED" -eq 1 ]; then
        release_meta_lock || true
        return 1
      fi
      release_meta_lock || true
      SKIPPED_LEGACY=1
      continue
    fi

    before="$STAGE_DIR/$id.before"
    after="$STAGE_DIR/$id.after"
    cp -p -- "$meta" "$before" || { release_meta_lock || true; return 1; }
    cp -p -- "$meta" "$after" || { release_meta_lock || true; return 1; }
    if [ -s "$after" ]; then
      last_byte=$(tail -c 1 "$after") || { release_meta_lock || true; return 1; }
      if [ -n "$last_byte" ]; then
        printf '\n' >> "$after" || { release_meta_lock || true; return 1; }
      fi
    fi
    printf 'endpoint_task_id=%s\n' "$id" >> "$after" || { release_meta_lock || true; return 1; }
    chmod 0600 "$before" "$after" || { release_meta_lock || true; return 1; }
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
    STAMP_SELECTED+=(1)
    STAMP_BEFORE_FINAL+=("$before_final")
    STAMP_AFTER_FINAL+=("$after_final")
    release_meta_lock || return 1
  done

  [ "$REPORT_WRITE_FAILED" -eq 0 ] || return 1
  acquire_apply_locks || return 1
  for i in "${!STAMP_IDS[@]}"; do
    if ! regular_file "${STAMP_METAS[$i]}" || ! cmp -s -- "${STAMP_METAS[$i]}" "${STAMP_BEFORE[$i]}"; then
      return 1
    fi
    if ! verify_legacy_endpoint "${STAMP_METAS[$i]}" "${STAMP_IDS[$i]}"; then
      [ "$REPORT_WRITE_FAILED" -eq 0 ] || return 1
      STAMP_SELECTED[$i]=0
      SKIPPED_LEGACY=1
      continue
    fi
    record_outcome "task ${STAMP_IDS[$i]}: stamped - exact live endpoint identity verified" || return 1
  done
  stage_records="$STAGE_DIR/records"
  : > "$stage_records" || return 1
  for i in "${!STAMP_IDS[@]}"; do
    [ "${STAMP_SELECTED[$i]:-0}" -eq 1 ] || continue
    printf '%s\t%s\t%s\n' "${STAMP_IDS[$i]}" "${STAMP_IDS[$i]}.before" "${STAMP_IDS[$i]}.after" >> "$stage_records" || return 1
  done
  chmod 0600 "$stage_records" || return 1
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
    records_before_tmp=$(mktemp "$STAGE_DIR/records.before.XXXXXX") || return 1
    if ! cp -p -- "$RECORDS" "$records_before_tmp" || ! chmod 0600 "$records_before_tmp"; then
      rm -f -- "$records_before_tmp"
      return 1
    fi
    RECORDS_BEFORE="$STAGE_DIR/records.before"
    if ! mv -f -- "$records_before_tmp" "$RECORDS_BEFORE"; then
      rm -f -- "$records_before_tmp"
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
    if ! chmod 0700 "$BACKUP_DIR"; then
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
  if [ "$RECORDS_EXISTING" -eq 1 ]; then
    cp -p -- "$RECORDS" "$manifest_tmp" || {
      rm -f -- "$manifest_tmp"
      abort_apply 1
      return $?
    }
  fi
  for i in "${!STAMP_IDS[@]}"; do
    [ "${STAMP_SELECTED[$i]:-0}" -eq 1 ] || continue
    printf '%s\t%s\t%s\n' "${STAMP_IDS[$i]}" "${STAMP_IDS[$i]}.before" "${STAMP_IDS[$i]}.after" >> "$manifest_tmp" || {
      rm -f -- "$manifest_tmp"
      abort_apply 1
      return $?
    }
  done
  if ! chmod 0600 "$manifest_tmp"; then
    rm -f -- "$manifest_tmp"
    abort_apply 1
    return $?
  fi
  RECORDS_PUBLISHED=1
  if ! mv -f -- "$manifest_tmp" "$RECORDS"; then
    rm -f -- "$manifest_tmp"
    abort_apply 1
    return $?
  fi

  META_WRITE_STARTED=1
  for i in "${!STAMP_IDS[@]}"; do
    [ "${STAMP_SELECTED[$i]:-0}" -eq 1 ] || continue
    if ! regular_file "${STAMP_METAS[$i]}" || ! cmp -s -- "${STAMP_METAS[$i]}" "${STAMP_BEFORE[$i]}"; then
      abort_apply 1
      return $?
    fi
    if ! verify_legacy_endpoint "${STAMP_METAS[$i]}" "${STAMP_IDS[$i]}"; then
      abort_apply 1
      return $?
    fi
    tmp=$(mktemp "$STATE/.endpoint-binding-meta.XXXXXX") || {
      abort_apply 1
      return $?
    }
    if ! cp -p -- "${STAMP_AFTER[$i]}" "$tmp" || ! mv -f -- "$tmp" "${STAMP_METAS[$i]}"; then
      rm -f -- "$tmp"
      abort_apply 1
      return $?
    fi
  done

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
  local source=$1 destination=$2 tmp
  regular_file "$source" || return 1
  tmp=$(mktemp "$STATE/.endpoint-binding-snapshot.XXXXXX") || return 1
  if ! cp -pP -- "$source" "$tmp" || ! regular_file "$tmp" || ! chmod 0600 "$tmp" \
    || ! copy_private_atomic "$tmp" "$destination"; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp" || true
}

surgical_remove_binding() {
  local meta=$1 id=$2 before=$3 after=$4 output=$5 binding binding_count
  local current_size after_size tmp last_byte
  SURGICAL_UNDO_CHANGED=0
  regular_file "$meta" || return 0
  binding="endpoint_task_id=$id"
  binding_count=$(awk -v expected="$binding" '$0 == expected { count++ } END { print count + 0 }' "$meta") || return 1
  [ "$binding_count" -eq 1 ] || return 0
  current_size=$(wc -c < "$meta") || return 1
  after_size=$(wc -c < "$after") || return 1
  [ "$current_size" -ge "$after_size" ] || return 0
  dd if="$meta" bs=1 count="$after_size" 2>/dev/null | cmp -s -- - "$after" || return 0
  tmp=$(mktemp "$STATE/.endpoint-binding-surgical-undo.XXXXXX") || return 1
  if ! cp -pP -- "$before" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [ "$current_size" -gt "$after_size" ]; then
    if [ -s "$before" ]; then
      last_byte=$(tail -c 1 "$before") || { rm -f -- "$tmp"; return 1; }
      [ -z "$last_byte" ] || printf '\n' >> "$tmp" || { rm -f -- "$tmp"; return 1; }
    fi
    if ! dd if="$meta" bs=1 skip="$after_size" 2>/dev/null >> "$tmp"; then
      rm -f -- "$tmp"
      return 1
    fi
  fi
  if ! chmod 0600 "$tmp" || ! copy_private_atomic "$tmp" "$output"; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp" || true
  SURGICAL_UNDO_CHANGED=1
}

replace_metadata_from_private() {
  local source=$1 meta=$2 tmp
  private_file "$source" && regular_file "$meta" || return 1
  tmp=$(mktemp "$STATE/.endpoint-binding-meta-replace.XXXXXX") || return 1
  if ! copy_private_atomic "$source" "$tmp" || ! regular_file "$meta" \
    || ! mv -f -- "$tmp" "$meta"; then
    rm -f -- "$tmp"
    return 1
  fi
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
  local id before_name after_name meta before after tmp i extra cleanup_stage cleanup_rc
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
  if ! chmod 0700 "$cleanup_stage"; then
    abort_undo
    return 1
  fi
  copy_private_atomic "$RECORDS" "$cleanup_stage/records" || { abort_undo; return 1; }
  for id in "${UNDO_IDS[@]}"; do
    if ! copy_private_atomic "$BACKUP_DIR/$id.before" "$cleanup_stage/$id.before" \
      || ! copy_private_atomic "$BACKUP_DIR/$id.after" "$cleanup_stage/$id.after"; then
      abort_undo
      return 1
    fi
  done
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
    UNDO_RECOVERY_BEFORE[$i]=$undone_snapshot
    UNDO_RECOVERY_AFTER[$i]=$current_snapshot
    UNDO_CHANGED=$((i + 1))
    UNDO_TOUCHED[$i]=1
    tmp=$(mktemp "$STATE/.endpoint-binding-undo.XXXXXX") || {
      abort_undo
      return $?
    }
    if ! cp -pP -- "$undone_snapshot" "$tmp" || ! mv -f -- "$tmp" "$meta"; then
      rm -f -- "$tmp"
      abort_undo
      return $?
    fi
    removed_count=$((removed_count + 1))
  done
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

recover_undo_stage || {
  echo "ENDPOINT_BINDING_MIGRATION: incomplete undo recovery failed" >&2
  exit 1
}

if [ "$MODE" = undo ]; then
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
