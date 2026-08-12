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
  printf '%s\n' "$1" >> "$REPORT_TMP"
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
SKIPPED_LEGACY=0
META_WRITE_STARTED=0
RECORDS_PUBLISHED=0
BACKUP_DIR_CREATED=0

cleanup() {
  local path
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
trap 'exit 1' HUP INT TERM

rollback_stamps() {
  local i tmp
  for i in "${!STAMP_IDS[@]}"; do
    tmp=$(mktemp "$STATE/.endpoint-binding-rollback.XXXXXX") || return 1
    if ! cp -p -- "${STAMP_BEFORE[$i]}" "$tmp" || ! mv -f -- "$tmp" "${STAMP_METAS[$i]}"; then
      rm -f -- "$tmp"
      return 1
    fi
  done
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
  if [ "$META_WRITE_STARTED" -eq 1 ]; then
    rollback_stamps || rc=1
  fi
  [ "$RECORDS_PUBLISHED" -eq 0 ] || rm -f -- "$RECORDS"
  remove_published_backups
  return "$rc"
}

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
  REPORT_TMP=$(mktemp "$STATE/.endpoint-binding-report.XXXXXX") || return 1
  chmod 0600 "$REPORT_TMP" || return 1
  STAGE_DIR=$(mktemp -d "$STATE/.endpoint-binding-stage.XXXXXX") || return 1
  chmod 0700 "$STAGE_DIR" || return 1

  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
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
    if ! verify_legacy_endpoint "$meta" "$id"; then
      SKIPPED_LEGACY=1
      continue
    fi

    before="$STAGE_DIR/$id.before"
    after="$STAGE_DIR/$id.after"
    cp -p -- "$meta" "$before" || return 1
    cp -p -- "$meta" "$after" || return 1
    printf 'endpoint_task_id=%s\n' "$id" >> "$after" || return 1
    chmod 0600 "$before" "$after" || return 1
    validation=$(fm_backend_validate_task_endpoint "$after" "$id" 2>&1) || {
      record_outcome "task $id: skipped - staged binding failed shared validation: $(reason_one_line "$validation")"
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
  done

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

  for i in "${!STAMP_IDS[@]}"; do
    [ -f "${STAMP_METAS[$i]}" ] && [ ! -L "${STAMP_METAS[$i]}" ] || {
      abort_apply 1
      return $?
    }
    cmp -s -- "${STAMP_METAS[$i]}" "${STAMP_BEFORE[$i]}" || {
      abort_apply 1
      return $?
    }
  done
  META_WRITE_STARTED=1
  for i in "${!STAMP_IDS[@]}"; do
    [ -f "${STAMP_METAS[$i]}" ] && [ ! -L "${STAMP_METAS[$i]}" ] || {
      abort_apply 1
      return $?
    }
    tmp=$(mktemp "$STATE/.endpoint-binding-meta.XXXXXX") || { abort_apply 1; return $?; }
    if ! cp -p -- "${STAMP_AFTER[$i]}" "$tmp" || ! mv -f -- "$tmp" "${STAMP_METAS[$i]}"; then
      rm -f -- "$tmp"
      abort_apply 1
      return $?
    fi
  done

  manifest_tmp=$(mktemp "$STATE/.endpoint-binding-records.XXXXXX") || { abort_apply 1; return $?; }
  for i in "${!STAMP_IDS[@]}"; do
    printf '%s\t%s\t%s\n' "${STAMP_IDS[$i]}" "${STAMP_IDS[$i]}.before" "${STAMP_IDS[$i]}.after" >> "$manifest_tmp" || {
      rm -f -- "$manifest_tmp"
      abort_apply 1
      return $?
    }
  done
  chmod 0600 "$manifest_tmp"
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
  local id before_name after_name meta before after tmp i changed=0 extra
  local -a undo_ids=() undo_metas=() undo_before=() undo_after=()
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
    cmp -s -- "$meta" "$after" || {
      echo "ENDPOINT_BINDING_MIGRATION: undo refused for task $id; metadata changed after stamping" >&2
      return 1
    }
    undo_ids+=("$id")
    undo_metas+=("$meta")
    undo_before+=("$before")
    undo_after+=("$after")
  done < "$RECORDS"

  for i in "${!undo_ids[@]}"; do
    tmp=$(mktemp "$STATE/.endpoint-binding-undo.XXXXXX") || return 1
    if ! cp -p -- "${undo_before[$i]}" "$tmp" || ! mv -f -- "$tmp" "${undo_metas[$i]}"; then
      rm -f -- "$tmp"
      for ((changed--; changed >= 0; changed--)); do
        tmp=$(mktemp "$STATE/.endpoint-binding-undo-rollback.XXXXXX") || return 1
        if ! cp -p -- "${undo_after[$changed]}" "$tmp" \
          || ! mv -f -- "$tmp" "${undo_metas[$changed]}"; then
          rm -f -- "$tmp"
          return 1
        fi
      done
      return 1
    fi
    changed=$((changed + 1))
  done
  rm -f -- "$SCAN_MARKER" "$MARKER" "$RECORDS"
  for id in "${undo_ids[@]}"; do
    rm -f -- "$BACKUP_DIR/$id.before" "$BACKUP_DIR/$id.after"
  done
  rmdir -- "$BACKUP_DIR" 2>/dev/null || true
  printf 'ENDPOINT_BINDING_MIGRATION: undid %s stamp(s)\n' "${#undo_ids[@]}"
}

if [ "$MODE" = undo ]; then
  undo_migration
else
  apply_migration
fi
