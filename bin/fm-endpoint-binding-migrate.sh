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
    ''|*[!A-Za-z0-9_:-]*) return 1 ;;
  esac
}

private_file() {
  [ -f "$1" ] && [ ! -L "$1" ]
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
UNDO_IDS=()
UNDO_METAS=()
UNDO_BEFORE=()
UNDO_AFTER=()
UNDO_TOUCHED=()
UNDO_CHANGED=0
UNDO_ACTIVE=0

cleanup() {
  local path
  [ "$RECOVERY_REQUIRED" -eq 1 ] && return 0
  [ -z "$REPORT_TMP" ] || rm -f -- "$REPORT_TMP"
  if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
    for path in "$STAGE_DIR"/*; do
      [ -e "$path" ] || continue
      rm -f -- "$path"
    done
    rmdir -- "$STAGE_DIR" 2>/dev/null || true
  fi
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

rollback_stamps() {
  local i tmp rc=0 meta
  for i in "${!STAMP_IDS[@]}"; do
    meta=${STAMP_METAS[$i]}
    if ! acquire_meta_lock "$meta"; then
      rc=1
      continue
    fi
    if ! private_file "$meta"; then
      rc=1
      release_meta_lock || rc=1
      continue
    fi
    if cmp -s -- "$meta" "${STAMP_BEFORE[$i]}"; then
      release_meta_lock || rc=1
      continue
    fi
    if ! cmp -s -- "$meta" "${STAMP_AFTER[$i]}"; then
      rc=1
      release_meta_lock || rc=1
      continue
    fi
    tmp=$(mktemp "$STATE/.endpoint-binding-rollback.XXXXXX") || {
      rc=1
      release_meta_lock || rc=1
      continue
    }
    if ! cp -p -- "${STAMP_BEFORE[$i]}" "$tmp" || ! mv -f -- "$tmp" "${STAMP_METAS[$i]}"; then
      rm -f -- "$tmp"
      rc=1
    fi
    release_meta_lock || rc=1
  done
  return "$rc"
}

remove_published_backups() {
  local i
  for i in "${!STAMP_IDS[@]}"; do
    rm -f -- "${STAMP_BEFORE_FINAL[$i]}" "${STAMP_AFTER_FINAL[$i]}"
  done
  [ "$BACKUP_DIR_CREATED" -eq 1 ] || return 0
  rmdir -- "$BACKUP_DIR" 2>/dev/null || true
}

abort_apply() {
  local rc=${1:-1}
  local rollback_rc=0 evidence_rc=0
  [ "$APPLY_ABORTED" -eq 0 ] || return "$rc"
  APPLY_ABORTED=1
  release_meta_lock || rc=1
  if [ "$META_WRITE_STARTED" -eq 1 ] && ! rollback_stamps; then
    rollback_rc=1
    rc=1
  fi
  restore_evidence || evidence_rc=1
  if [ "$rollback_rc" -eq 0 ] && [ "$evidence_rc" -eq 0 ]; then
    [ "$RECORDS_PUBLISHED" -eq 0 ] || rm -f -- "$RECORDS" || rc=1
    remove_published_backups || rc=1
  else
    RECOVERY_REQUIRED=1
    if [ "$META_WRITE_STARTED" -eq 1 ] && [ "${#STAMP_IDS[@]}" -gt 0 ]; then
      publish_recovery_records || rc=1
    fi
  fi
  return "$rc"
}

handle_signal() {
  trap - HUP INT TERM
  if [ "$MODE" = undo ] && [ "$UNDO_ACTIVE" -eq 1 ]; then
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
  snapshot_evidence_file "$REPORT" report || return 1
  snapshot_evidence_file "$SCAN_MARKER" scan-marker || return 1
  snapshot_evidence_file "$MARKER" marker || return 1
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

undo_rollback_changed() {
  local index tmp rc=0 meta
  for ((index=UNDO_CHANGED - 1; index >= 0; index--)); do
    [ "${UNDO_TOUCHED[$index]:-0}" -eq 1 ] || continue
    meta=${UNDO_METAS[$index]}
    if ! acquire_meta_lock "$meta"; then
      rc=1
      continue
    fi
    if ! private_file "$meta"; then
      rc=1
      release_meta_lock || rc=1
      continue
    fi
    if cmp -s -- "$meta" "${UNDO_BEFORE[$index]}"; then
      tmp=$(mktemp "$STATE/.endpoint-binding-undo-rollback.XXXXXX") || {
        rc=1
        release_meta_lock || rc=1
        continue
      }
      if ! cp -p -- "${UNDO_AFTER[$index]}" "$tmp" \
        || ! mv -f -- "$tmp" "$meta"; then
        rm -f -- "$tmp"
        rc=1
      fi
    elif ! cmp -s -- "$meta" "${UNDO_AFTER[$index]}"; then
      rc=1
    fi
    release_meta_lock || rc=1
  done
  return "$rc"
}

abort_undo() {
  local rc=1
  release_meta_lock || rc=1
  undo_rollback_changed || rc=1
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
  local meta id binding_count validation before after before_final after_final
  local i tmp manifest_tmp
  STAGE_DIR=$(mktemp -d "$STATE/.endpoint-binding-stage.XXXXXX") || return 1
  chmod 0700 "$STAGE_DIR" || return 1
  REPORT_TMP=$(mktemp "$STAGE_DIR/report.XXXXXX") || return 1
  chmod 0600 "$REPORT_TMP" || return 1
  prepare_evidence || return 1

  for meta in "$STATE"/*.meta; do
    [ "$meta" = "$STATE/*.meta" ] && continue
    id=${meta##*/}
    id=${id%.meta}
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
      if [ "$binding_count" -eq 1 ] && [ "$(fm_meta_get "$meta" endpoint_task_id)" = "$id" ]; then
        record_outcome "task $id: untouched - endpoint_task_id already present"
      else
        record_outcome "task $id: untouched - existing endpoint_task_id binding is ambiguous or mismatched"
      fi
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
    STAMP_BEFORE_FINAL+=("$before_final")
    STAMP_AFTER_FINAL+=("$after_final")
    record_outcome "task $id: stamped - exact live endpoint identity verified"
    if [ "$REPORT_WRITE_FAILED" -eq 1 ]; then
      release_meta_lock || true
      return 1
    fi
    release_meta_lock || return 1
  done

  [ "$REPORT_WRITE_FAILED" -eq 0 ] || return 1
  if [ "${#STAMP_IDS[@]}" -eq 0 ]; then
    publish_report || return 1
    write_marker "$SCAN_MARKER" fm-endpoint-binding-migration-scan-v1 || return 1
    if [ "$SKIPPED_LEGACY" -eq 0 ]; then
      write_marker "$MARKER" fm-endpoint-binding-migration-v1 || return 1
    fi
    printf 'ENDPOINT_BINDING_MIGRATION: scanned %s record(s); stamped 0\n' "$OUTCOME_COUNT"
    cat "$REPORT"
    return 0
  fi

  if [ -e "$RECORDS" ] || [ -L "$RECORDS" ]; then
    echo "ENDPOINT_BINDING_MIGRATION: an existing stamp journal requires undo before new stamps; migration did not run" >&2
    return 1
  fi
  for i in "${!STAMP_IDS[@]}"; do
    if [ -e "${STAMP_BEFORE_FINAL[$i]}" ] || [ -L "${STAMP_BEFORE_FINAL[$i]}" ] \
      || [ -e "${STAMP_AFTER_FINAL[$i]}" ] || [ -L "${STAMP_AFTER_FINAL[$i]}" ]; then
      return 1
    fi
  done
  if [ -e "$BACKUP_DIR" ] || [ -L "$BACKUP_DIR" ]; then
    [ -d "$BACKUP_DIR" ] && [ ! -L "$BACKUP_DIR" ] || return 1
  else
    mkdir -- "$BACKUP_DIR" || return 1
    BACKUP_DIR_CREATED=1
    if ! chmod 0700 "$BACKUP_DIR"; then
      remove_published_backups
      return 1
    fi
  fi
  for i in "${!STAMP_IDS[@]}"; do
    cp -p -- "${STAMP_BEFORE[$i]}" "${STAMP_BEFORE_FINAL[$i]}" || { remove_published_backups; return 1; }
    cp -p -- "${STAMP_AFTER[$i]}" "${STAMP_AFTER_FINAL[$i]}" || { remove_published_backups; return 1; }
    chmod 0600 "${STAMP_BEFORE_FINAL[$i]}" "${STAMP_AFTER_FINAL[$i]}" || { remove_published_backups; return 1; }
  done

  META_WRITE_STARTED=1
  for i in "${!STAMP_IDS[@]}"; do
    acquire_meta_lock "${STAMP_METAS[$i]}" || { abort_apply 1; return $?; }
    if ! private_file "${STAMP_METAS[$i]}" || ! cmp -s -- "${STAMP_METAS[$i]}" "${STAMP_BEFORE[$i]}"; then
      release_meta_lock || true
      abort_apply 1
      return $?
    fi
    tmp=$(mktemp "$STATE/.endpoint-binding-meta.XXXXXX") || {
      release_meta_lock || true
      abort_apply 1
      return $?
    }
    if ! cp -p -- "${STAMP_AFTER[$i]}" "$tmp" || ! mv -f -- "$tmp" "${STAMP_METAS[$i]}"; then
      rm -f -- "$tmp"
      release_meta_lock || true
      abort_apply 1
      return $?
    fi
    release_meta_lock || { abort_apply 1; return $?; }
  done

  manifest_tmp=$(mktemp "$STATE/.endpoint-binding-records.XXXXXX") || { abort_apply 1; return $?; }
  for i in "${!STAMP_IDS[@]}"; do
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
  if ! mv -f -- "$manifest_tmp" "$RECORDS"; then
    rm -f -- "$manifest_tmp"
    abort_apply 1
    return $?
  fi
  RECORDS_PUBLISHED=1
  if ! publish_report; then abort_apply 1; return $?; fi
  if ! write_marker "$SCAN_MARKER" fm-endpoint-binding-migration-scan-v1; then abort_apply 1; return $?; fi
  if [ "$SKIPPED_LEGACY" -eq 0 ]; then
    if ! write_marker "$MARKER" fm-endpoint-binding-migration-v1; then abort_apply 1; return $?; fi
  fi
  printf 'ENDPOINT_BINDING_MIGRATION: scanned %s record(s); stamped %s\n' "$OUTCOME_COUNT" "${#STAMP_IDS[@]}"
  cat "$REPORT"
}

undo_migration() {
  local id before_name after_name meta before after tmp i extra
  UNDO_IDS=()
  UNDO_METAS=()
  UNDO_BEFORE=()
  UNDO_AFTER=()
  UNDO_TOUCHED=()
  UNDO_CHANGED=0
  private_file "$RECORDS" || {
    echo "ENDPOINT_BINDING_MIGRATION: no recorded stamps to undo"
    return 0
  }
  while IFS=$'\t' read -r id before_name after_name extra || [ -n "${id:-}${before_name:-}${after_name:-}${extra:-}" ]; do
    [ -n "${id:-}" ] && [ -z "${extra:-}" ] || return 1
    valid_task_id "$id" || return 1
    [ "$before_name" = "$id.before" ] && [ "$after_name" = "$id.after" ] || return 1
    meta="$STATE/$id.meta"
    before="$BACKUP_DIR/$before_name"
    after="$BACKUP_DIR/$after_name"
    private_file "$meta" && private_file "$before" && private_file "$after" || return 1
    cmp -s -- "$meta" "$after" || cmp -s -- "$meta" "$before" || {
      echo "ENDPOINT_BINDING_MIGRATION: undo refused for task $id; metadata changed after stamping" >&2
      return 1
    }
    UNDO_IDS+=("$id")
    UNDO_METAS+=("$meta")
    UNDO_BEFORE+=("$before")
    UNDO_AFTER+=("$after")
  done < "$RECORDS"

  UNDO_ACTIVE=1
  for i in "${!UNDO_IDS[@]}"; do
    acquire_meta_lock "${UNDO_METAS[$i]}" || { abort_undo; return $?; }
    if ! private_file "${UNDO_METAS[$i]}"; then
      release_meta_lock || true
      abort_undo
      return $?
    fi
    if cmp -s -- "${UNDO_METAS[$i]}" "${UNDO_BEFORE[$i]}"; then
      release_meta_lock || { abort_undo; return $?; }
      continue
    fi
    if ! cmp -s -- "${UNDO_METAS[$i]}" "${UNDO_AFTER[$i]}"; then
      release_meta_lock || true
      echo "ENDPOINT_BINDING_MIGRATION: undo refused for task ${UNDO_IDS[$i]}; metadata changed after stamping" >&2
      abort_undo
      return $?
    fi
    UNDO_CHANGED=$((i + 1))
    UNDO_TOUCHED[$i]=1
    tmp=$(mktemp "$STATE/.endpoint-binding-undo.XXXXXX") || {
      release_meta_lock || true
      abort_undo
      return $?
    }
    if ! cp -p -- "${UNDO_BEFORE[$i]}" "$tmp" || ! mv -f -- "$tmp" "${UNDO_METAS[$i]}"; then
      rm -f -- "$tmp"
      release_meta_lock || true
      abort_undo
      return $?
    fi
    release_meta_lock || { abort_undo; return $?; }
  done
  UNDO_ACTIVE=0
  local cleanup_rc=0
  rm -f -- "$SCAN_MARKER" || cleanup_rc=1
  [ "$cleanup_rc" -eq 0 ] && rm -f -- "$MARKER" || cleanup_rc=1
  if [ "$cleanup_rc" -eq 0 ]; then
    for id in "${UNDO_IDS[@]}"; do
      rm -f -- "$BACKUP_DIR/$id.before" "$BACKUP_DIR/$id.after" || {
        cleanup_rc=1
        break
      }
    done
  fi
  [ "$cleanup_rc" -eq 0 ] && rmdir -- "$BACKUP_DIR" 2>/dev/null || cleanup_rc=1
  [ "$cleanup_rc" -eq 0 ] && rm -f -- "$RECORDS" || cleanup_rc=1
  if [ "$cleanup_rc" -ne 0 ]; then
    echo "ENDPOINT_BINDING_MIGRATION: undo restored metadata but cleanup failed; migration evidence was retained" >&2
    return 1
  fi
  printf 'ENDPOINT_BINDING_MIGRATION: undid %s stamp(s)\n' "${#UNDO_IDS[@]}"
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
