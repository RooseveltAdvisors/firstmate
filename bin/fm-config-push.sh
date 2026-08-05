#!/usr/bin/env bash
# Push declared inherited local material to live secondmate homes.
# Usage: fm-config-push.sh [--help]
#        fm-config-push.sh --remote-receive <secondmate-id>  # SSH-internal
#
# Mid-session convergence for inherited local material such as
# config/crew-dispatch.json edits or data/captain-shared.md updates. This
# discovers live secondmate homes from state/*.meta, backfills
# home= from data/secondmates.md for older meta records, and reuses the same
# propagation machinery as bootstrap, but deliberately does not
# fast-forward tracked files.
# After a successful per-home propagation that changes any allowlisted config/*
# item, writes a generation-specific literal-content reread instruction and
# sends its pointer to that live secondmate via fm-config-inherit-lib.sh
# (fm_config_send_reread_nudge).
# Unchanged config and data/captain-shared.md-only updates send no reread
# message unless a previous send failure is pending for that home.
# Warnings-only skips exit 0; real propagation or reread-send errors exit non-zero.
# For a route with host=, the parent streams only the fixed allowlist over strict
# SSH to this script's --remote-receive mode in the existing remote home.
set -u

usage() {
  cat <<'EOF'
Usage: fm-config-push.sh [--help]

Push the primary firstmate home's declared inherited local material into each
live secondmate home.

This is local-material-only:
  - does not fast-forward tracked files
  - after successful config/* changes, writes a generation-specific
    literal-content reread instruction and sends its pointer to that live secondmate
    (no message when config is unchanged unless a previous send failure is pending)
  - reports each live home and each inheritable item as pushed, unchanged,
    skipped, or error
  - exits non-zero for real propagation errors or reread-send failures

Live homes come from state/*.meta records with kind=secondmate.
data/secondmates.md is only a fallback for missing home= fields in older or
incomplete meta records.

Environment overrides follow the rest of firstmate:
  FM_HOME            active firstmate home
  FM_ROOT_OVERRIDE  firstmate repo root
  FM_STATE_OVERRIDE state dir
  FM_DATA_OVERRIDE  data dir
  FM_CONFIG_OVERRIDE config dir

--remote-receive is the noninteractive SSH endpoint used by another Firstmate
home. It accepts only the declared inheritance archive on stdin, applies it
through fm-config-inherit-lib.sh, and never launches or manages Herdr.
EOF
}

REMOTE_RECEIVE_ID=
case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    ;;
  --remote-receive)
    [ "$#" -eq 2 ] || { echo "usage: fm-config-push.sh --remote-receive <secondmate-id>" >&2; exit 2; }
    REMOTE_RECEIVE_ID=$2
    ;;
  *)
    echo "usage: fm-config-push.sh [--help]" >&2
    exit 2
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SECONDMATES_MD="$DATA/secondmates.md"

"$SCRIPT_DIR/fm-guard.sh" || true

# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-ssh-lib.sh
. "$SCRIPT_DIR/fm-ssh-lib.sh"

print_item_report() {
  local report=$1 item status reason
  while IFS=$'\t' read -r item status reason; do
    [ -n "$item" ] || continue
    if [ -n "$reason" ]; then
      printf '  %s: %s - %s\n' "$item" "$status" "$reason"
    else
      printf '  %s: %s\n' "$item" "$status"
    fi
  done < "$report"
}

config_push_archive() {  # <archive>
  local archive=$1 stage item src dest rc=0
  stage=$(mktemp -d "${TMPDIR:-/tmp}/fm-config-push.XXXXXX") || return 1
  mkdir -p "$stage/config" "$stage/data" || { rm -rf "$stage"; return 1; }
  for item in $FM_INHERITABLE_CONFIG; do
    src="$CONFIG/$item"
    dest="$stage/config/$item"
    [ -e "$src" ] || [ -L "$src" ] || continue
    if [ ! -f "$src" ] || [ -L "$src" ] || [ "$(fm_inherit_file_link_count "$src")" != 1 ]; then
      rc=1
      break
    fi
    cp "$src" "$dest" || { rc=1; break; }
  done
  src="$DATA/$FM_SHARED_CAPTAIN_FILE"
  if [ "$rc" -eq 0 ] && { [ -e "$src" ] || [ -L "$src" ]; }; then
    if ! shared_captain_file_safe_existing "$src" || ! shared_captain_header_valid "$src"; then
      rc=1
    else
      cp "$src" "$stage/data/$FM_SHARED_CAPTAIN_FILE" || rc=1
    fi
  fi
  [ "$rc" -ne 0 ] || tar -cf "$archive" -C "$stage" . || rc=1
  rm -rf "$stage"
  return "$rc"
}

config_push_remote_receive() {  # <id>; archive on stdin
  local id=$1 stage archive list path item report home_lock out rc=0
  fm_remote_id_valid "$id" || return 1
  [ -f "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] \
    && [ "$(cat "$FM_HOME/.fm-secondmate-home" 2>/dev/null)" = "$id" ] || return 1
  stage=$(mktemp -d "${TMPDIR:-/tmp}/fm-config-receive.XXXXXX") || return 1
  archive=$(mktemp "${TMPDIR:-/tmp}/fm-config-receive-archive.XXXXXX") || { rm -rf "$stage"; return 1; }
  list=$(mktemp "${TMPDIR:-/tmp}/fm-config-receive-list.XXXXXX") || { rm -rf "$stage"; rm -f "$archive"; return 1; }
  report=$(mktemp "${TMPDIR:-/tmp}/fm-config-receive-report.XXXXXX") || { rm -rf "$stage"; rm -f "$archive" "$list"; return 1; }
  cat >"$archive" || rc=1
  [ "$rc" -ne 0 ] || tar -tf "$archive" >"$list" 2>/dev/null || rc=1
  if [ "$rc" -eq 0 ]; then
    while IFS= read -r path; do
      case "$path" in
        ./|./config/|./data/|"./data/$FM_SHARED_CAPTAIN_FILE") ;;
        ./config/*)
          item=${path#./config/}
          case " $FM_INHERITABLE_CONFIG " in *" $item "*) ;; *) rc=1; break ;; esac
          ;;
        *) rc=1; break ;;
      esac
    done <"$list"
  fi
  [ "$rc" -ne 0 ] || tar -xf "$archive" -C "$stage" 2>/dev/null || rc=1
  for item in $FM_INHERITABLE_CONFIG; do
    path="$stage/config/$item"
    [ ! -e "$path" ] && [ ! -L "$path" ] && continue
    [ -f "$path" ] && [ ! -L "$path" ] || rc=1
  done
  path="$stage/data/$FM_SHARED_CAPTAIN_FILE"
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    home_lock=$(fm_config_inherit_lock_path "$FM_HOME") || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    fm_lock_acquire_wait "$home_lock" || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    FM_CONFIG_INHERIT_REPORT="$report" \
      propagate_secondmate_inheritance "$stage" "$FM_HOME" "$stage/config" "$stage/data" || rc=1
    if ! out=$(FM_CONFIG_REREAD_SKIP_PENDING=0 fm_config_send_reread_nudge "$id" "$FM_HOME" "$report" 2>&1); then
      [ -z "$out" ] || printf '%s\n' "$out" >&2
      rc=1
    fi
    fm_lock_release "$home_lock" || true
  fi
  print_item_report "$report"
  rm -rf "$stage"
  rm -f "$archive" "$list" "$report"
  return "$rc"
}

if [ -n "$REMOTE_RECEIVE_ID" ]; then
  config_push_remote_receive "$REMOTE_RECEIVE_ID"
  exit $?
fi

records=$(mktemp "${TMPDIR:-/tmp}/fm-config-push-records.XXXXXX" 2>/dev/null) || exit 1
reports=""
# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local report_file
  rm -f "$records"
  for report_file in $reports; do
    rm -f "$report_file"
  done
}
trap cleanup EXIT

live_secondmate_meta_records "$STATE" "$SECONDMATES_MD" > "$records"
if [ ! -s "$records" ]; then
  echo "config-push: no live secondmate homes found"
  exit 0
fi

echo "config-push: $FM_HOME -> live secondmate homes"

seen_homes=""
errors=0
while IFS='|' read -r id home _window meta; do
  [ -n "$id" ] || continue
  if fm_secondmate_remote_identity "$meta" "$SECONDMATES_MD" "$id"; then
    remote_backend=$(grep '^backend=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$remote_backend" ] || remote_backend=tmux
    if [ "$remote_backend" != herdr ]; then
      printf 'secondmate %s: skipped - remote Secondmate backend must be Herdr\n' "$id"
      errors=1
      continue
    fi
    identity="$FM_REMOTE_HOST:$FM_REMOTE_HOME"
    case " $seen_homes " in
      *" $identity "*) printf 'secondmate %s (%s): skipped - already processed for another live meta\n' "$id" "$identity"; continue ;;
    esac
    seen_homes="$seen_homes $identity"
    printf 'secondmate %s (%s):\n' "$id" "$identity"
    archive=$(mktemp "${TMPDIR:-/tmp}/fm-config-push-archive.XXXXXX") || { errors=1; continue; }
    reports="$reports $archive"
    if ! config_push_archive "$archive"; then
      echo "  inheritance: error - could not build safe archive"
      errors=1
      continue
    fi
    remote_rc=0
    fm_ssh_run "$FM_REMOTE_HOST" env "FM_HOME=$FM_REMOTE_HOME" "FM_ROOT_OVERRIDE=$FM_REMOTE_HOME" \
      "$FM_REMOTE_HOME/bin/fm-config-push.sh" --remote-receive "$id" <"$archive" || remote_rc=$?
    if [ "$remote_rc" -ne 0 ]; then
      if [ "$remote_rc" -eq "$FM_SSH_UNREACHABLE_RC" ]; then
        echo "  inheritance: unreachable"
      else
        echo "  inheritance: error - remote receive unreadable"
      fi
      errors=1
    fi
    continue
  elif [ "$?" -eq 2 ]; then
    printf 'secondmate %s: skipped - invalid remote identity\n' "$id"
    errors=1
    continue
  fi
  if [ -z "$home" ]; then
    printf 'secondmate %s: skipped - no home= in %s and no registry home\n' "$id" "$meta"
    continue
  fi
  if ! validate_secondmate_home "$id" "$home"; then
    printf 'secondmate %s (%s): skipped - unsafe home: %s\n' "$id" "$home" "$VALIDATION_ERROR"
    continue
  fi
  home_real="$VALIDATED_HOME"
  case " $seen_homes " in
    *" $home_real "*)
      printf 'secondmate %s (%s): skipped - already processed for another live meta\n' "$id" "$home_real"
      continue
      ;;
  esac
  seen_homes="$seen_homes $home_real"

  printf 'secondmate %s (%s):\n' "$id" "$home_real"
  dirty=$(dirty_status "$home_real" yes || true)
  if [ -n "$dirty" ]; then
    echo "  home: dirty working tree - local-material push continuing"
  fi

  mkdir -p "$home_real/state" || {
    echo "  config-reread: error - could not create state directory"
    errors=1
    continue
  }
  home_lock=$(fm_config_inherit_lock_path "$home_real") || {
    echo "  config-reread: error - could not resolve per-home lock"
    errors=1
    continue
  }
  fm_lock_acquire_wait "$home_lock" || {
    echo "  config-reread: error - could not acquire per-home lock"
    errors=1
    continue
  }
  if fm_config_reread_retry_queue_is_full "$FM_HOME" "$id"; then
    fm_config_reread_retry_pending "$id" "$home_real" || true
    if fm_config_reread_retry_queue_is_full "$FM_HOME" "$id"; then
      echo "  config-reread: error - retry instruction queue is full"
      errors=1
      fm_lock_release "$home_lock" || true
      continue
    fi
  fi

  report=$(mktemp "${TMPDIR:-/tmp}/fm-config-push-report.XXXXXX" 2>/dev/null) || {
    echo "  home: error - could not create report file"
    errors=1
    fm_lock_release "$home_lock" || true
    continue
  }
  reports="$reports $report"
  if FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$FM_HOME" "$home_real" "$CONFIG" "$DATA"; then
    :
  else
    errors=1
  fi
  print_item_report "$report"
  reread_pending=0
  if fm_config_reread_has_pending "$home_real" || fm_config_reread_has_staged "$FM_HOME" "$id"; then
    reread_pending=1
  fi
  if reread_out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_STATE_OVERRIDE="$STATE" \
    fm_config_send_reread_nudge "$id" "$home_real" "$report" 2>&1); then
    if [ -n "$(fm_config_reread_changed_items "$report")" ] || [ "$reread_pending" -eq 1 ]; then
      printf '  config-reread: sent\n'
    fi
    [ -z "$reread_out" ] || printf '%s\n' "$reread_out"
  else
    errors=1
    if [ -n "$reread_out" ]; then
      printf '%s\n' "$reread_out"
    else
      printf '  config-reread: send failed\n'
    fi
  fi
  fm_lock_release "$home_lock" || true
done < "$records"

[ "$errors" -eq 0 ] || exit 1
exit 0
