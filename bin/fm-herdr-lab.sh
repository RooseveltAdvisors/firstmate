#!/usr/bin/env bash
# Provision and operate an isolated Herdr lab session without risking the live
# default session.
#
# Usage:
#   fm-herdr-lab.sh name <label>
#   fm-herdr-lab.sh prepare <session>
#   fm-herdr-lab.sh provision <session>
#   fm-herdr-lab.sh bootstrap-pane <session>
#   fm-herdr-lab.sh run <session> <herdr arguments...>
#   fm-herdr-lab.sh stop <session>
#   fm-herdr-lab.sh teardown <session>
#
# Session names must begin with "fm-lab-" and can never be "default".
# The name command sanitizes the label, caps it at 16 characters, and appends
# process/random suffixes to keep generated socket paths short.
# Every Herdr call made here carries a trailing --session <session>.
# The run command rejects caller-supplied --session flags, any leading option
# before the subcommand, all session lifecycle operations, and every server
# operation.
# Session stop is available only through guarded stop or teardown, and session
# delete is available only through teardown.
# Both paths perform a fresh refuse-default check immediately before each
# destructive call.
# Provision records the running default session as a fleet-state tripwire and
# teardown requires that record to be identical afterward.
# Bootstrap-pane requires an owned running zero-pane lab, attaches one isolated
# PTY client, and prints {"session":...,"pane_id":...,"client_pid":...}.
set -u

fm_herdr_lab_error() {
  echo "fm-herdr-lab: $*" >&2
}

fm_herdr_lab_validate_name() { # <session>
  local name=${1:-}
  [[ "$name" =~ ^fm-lab-[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] && return 0
  case "$name" in
    default) fm_herdr_lab_error "refusing session name 'default'" ;;
    '') fm_herdr_lab_error "refusing an empty session name" ;;
    *) fm_herdr_lab_error "session name must start with 'fm-lab-' and contain only letters, digits, underscores, or dashes: $name" ;;
  esac
  return 1
}

fm_herdr_lab_state_dir() {
  printf '%s' "${FM_HERDR_LAB_STATE_DIR:-${TMPDIR:-/tmp}/fm-herdr-lab-${UID}}"
}

fm_herdr_lab_tripwire_path() { # <session>
  printf '%s/%s.fleet-state.json' "$(fm_herdr_lab_state_dir)" "$1"
}

fm_herdr_lab_bootstrap_dir() { # <session>
  printf '%s/%s.bootstrap-client' "$(fm_herdr_lab_state_dir)" "$1"
}

fm_herdr_lab_bootstrap_record_path() { # <session>
  printf '%s/client.state' "$(fm_herdr_lab_bootstrap_dir "$1")"
}

fm_herdr_lab_bootstrap_log_path() { # <session>
  printf '%s/client.log' "$(fm_herdr_lab_bootstrap_dir "$1")"
}

fm_herdr_lab_raw() { # <session> <herdr arguments...>
  local name=$1
  shift
  HERDR_SESSION="$name" herdr "$@" --session "$name"
}

fm_herdr_lab_session_list() { # <session>
  fm_herdr_lab_raw "$1" session list --json
}

fm_herdr_lab_fleet_state() { # <session>
  local name=$1 sessions snapshot
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot read Herdr sessions for the fleet-state tripwire"
    return 1
  }
  snapshot=$(printf '%s' "$sessions" | jq -c '
    [.sessions[]? | select(.default == true)]
    | if length == 1 and .[0].name == "default" and .[0].running == true
      then .[0] | {name, default, running, socket_path}
      else empty
      end
  ' 2>/dev/null)
  [ -n "$snapshot" ] || {
    fm_herdr_lab_error "fleet-state tripwire requires exactly one running default session"
    return 1
  }
  printf '%s\n' "$snapshot"
}

fm_herdr_lab_prepare() { # <session>
  local name=$1 sessions state_dir tripwire
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }

  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before provisioning '$name'"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    fm_herdr_lab_error "session '$name' already exists; refusing to adopt or overwrite it"
    return 1
  fi

  state_dir=$(fm_herdr_lab_state_dir)
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  mkdir -p "$state_dir" || return 1
  [ ! -e "$tripwire" ] || {
    fm_herdr_lab_error "tripwire already exists for '$name'; refusing ambiguous ownership"
    return 1
  }
  fm_herdr_lab_fleet_state "$name" > "$tripwire" || {
    rm -f "$tripwire"
    return 1
  }
}

fm_herdr_lab_refuse_if_default() { # <session>
  local name=$1 info flag
  fm_herdr_lab_validate_name "$name" || return 1
  info=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "refusing destructive call because session list failed"
    return 1
  }
  flag=$(printf '%s' "$info" | jq -r --arg name "$name" \
    '.sessions[]? | select(.name == $name) | .default' 2>/dev/null)
  [ "$flag" = false ] && return 0
  fm_herdr_lab_error "refusing destructive call for '$name': session is absent or default (default=${flag:-<not found>})"
  return 1
}

fm_herdr_lab_cli() { # <session> <herdr arguments...>
  local name=$1 arg
  shift
  fm_herdr_lab_validate_name "$name" || return 1
  [ "$#" -gt 0 ] || { fm_herdr_lab_error "run requires Herdr arguments"; return 1; }
  case "$1" in
    -*)
      fm_herdr_lab_error "run forbids a leading option before the Herdr subcommand; it could shift a server or session lifecycle operation past the guard or subvert session isolation"
      return 1
      ;;
  esac
  for arg in "$@"; do
    case "$arg" in
      --session|--session=*)
        fm_herdr_lab_error "run forbids caller-supplied --session; the helper appends the lab session"
        return 1
        ;;
    esac
  done
  case "$1 ${2:-}" in
    "server "*)
      fm_herdr_lab_error "run forbids server operations; use provision for the named lab server"
      return 1
      ;;
    "session list") ;;
    "session "*)
      fm_herdr_lab_error "run forbids session lifecycle operations; use guarded teardown"
      return 1
      ;;
  esac
  fm_herdr_lab_raw "$name" "$@"
}

fm_herdr_lab_cancel_provision() { # <pid>
  local pid=$1 attempt=0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 10 ]; do
      sleep 0.1
      attempt=$((attempt + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

fm_herdr_lab_provision() { # <session>
  local name=$1 sessions tripwire running attempt server_pid max_attempts timeout_seconds
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }

  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before provisioning '$name'"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    tripwire=$(fm_herdr_lab_tripwire_path "$name")
    [ -f "$tripwire" ] || {
      fm_herdr_lab_error "missing fleet-state tripwire for existing session '$name'; refusing to adopt it"
      return 1
    }
    fm_herdr_lab_refuse_if_default "$name" || return 1
    running=$(printf '%s' "$sessions" | jq -r --arg name "$name" \
      '.sessions[]? | select(.name == $name) | .running' 2>/dev/null)
    [ "$running" = false ] || {
      fm_herdr_lab_error "session '$name' is not stopped; refusing to re-provision it"
      return 1
    }
    fm_herdr_lab_check_tripwire "$name" || return 1
  else
    fm_herdr_lab_prepare "$name" || return 1
  fi
  fm_herdr_lab_raw "$name" server >/dev/null 2>&1 &
  server_pid=$!
  attempt=0
  max_attempts=300
  timeout_seconds=60
  while [ "$attempt" -lt 100 ]; do
    running=$(fm_herdr_lab_cli "$name" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null) || running=false
    if [ "$running" = true ]; then
      fm_herdr_lab_refuse_if_default "$name" || {
        fm_herdr_lab_cancel_provision "$server_pid"
        return 1
      }
      return 0
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done
  fm_herdr_lab_cancel_provision "$server_pid"
  fm_herdr_lab_error "lab session '$name' did not report running within $timeout_seconds seconds"
  return 1
}

fm_herdr_lab_check_tripwire() { # <session>
  local name=$1 tripwire before after
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] && [ ! -L "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing unverified teardown"
    return 1
  }
  before=$(cat "$tripwire")
  after=$(fm_herdr_lab_fleet_state "$name") || return 1
  [ "$before" = "$after" ] || {
    fm_herdr_lab_error "FLEET-STATE TRIPWIRE FAILED: default session changed during lab work"
    fm_herdr_lab_error "before: $before"
    fm_herdr_lab_error "after:  $after"
    return 1
  }
}

fm_herdr_lab_verify_tripwire() { # <session>
  local name=$1 tripwire
  fm_herdr_lab_check_tripwire "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  rm -f "$tripwire"
}

fm_herdr_lab_process_start() { # <pid>
  local pid=$1 raw rest
  local -a fields
  [ -r "/proc/$pid/stat" ] || return 1
  raw=$(<"/proc/$pid/stat") || return 1
  rest=${raw#*) }
  read -r -a fields <<< "$rest"
  [ "${#fields[@]}" -ge 20 ] || return 1
  [[ "${fields[19]}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${fields[19]}"
}

fm_herdr_lab_process_state() { # <pid>
  local pid=$1 raw rest
  local -a fields
  [ -r "/proc/$pid/stat" ] || return 1
  raw=$(<"/proc/$pid/stat") || return 1
  rest=${raw#*) }
  read -r -a fields <<< "$rest"
  [ "${#fields[@]}" -ge 1 ] || return 1
  printf '%s\n' "${fields[0]}"
}

fm_herdr_lab_process_has_owner() { # <pid> <owner-token>
  local pid=$1 owner=$2 entry
  [ -r "/proc/$pid/environ" ] || return 1
  while IFS= read -r -d '' entry; do
    [ "$entry" = "FM_HERDR_LAB_BOOTSTRAP_OWNER=$owner" ] && return 0
  done < "/proc/$pid/environ"
  return 1
}

fm_herdr_lab_single_child_pid() { # <pid>
  local pid=$1 raw
  local -a children
  [ -r "/proc/$pid/task/$pid/children" ] || return 1
  raw=$(<"/proc/$pid/task/$pid/children") || return 1
  read -r -a children <<< "$raw"
  [ "${#children[@]}" -eq 1 ] || return 1
  [[ "${children[0]}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${children[0]}"
}

fm_herdr_lab_write_bootstrap_record() { # <session> <client-pid> <client-start> <attach-pid> <attach-start> <owner> [pane]
  local name=$1 client_pid=$2 client_start=$3 attach_pid=$4 attach_start=$5 owner=$6 pane=${7:-} record tmp
  record=$(fm_herdr_lab_bootstrap_record_path "$name")
  tmp="$record.tmp.$$"
  (umask 077; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$client_pid" "$client_start" "$attach_pid" "$attach_start" "$owner" "$pane" > "$tmp") \
    || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$record"
}

fm_herdr_lab_read_bootstrap_record() { # <session>; sets FM_HERDR_LAB_BOOTSTRAP_*
  local name=$1 dir record extra
  dir=$(fm_herdr_lab_bootstrap_dir "$name")
  record=$(fm_herdr_lab_bootstrap_record_path "$name")
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$record" ] && [ ! -L "$record" ] || {
    fm_herdr_lab_error "bootstrap client state for '$name' is absent or ambiguous"
    return 1
  }
  IFS=$'\t' read -r \
    FM_HERDR_LAB_BOOTSTRAP_SESSION \
    FM_HERDR_LAB_BOOTSTRAP_PID \
    FM_HERDR_LAB_BOOTSTRAP_START \
    FM_HERDR_LAB_BOOTSTRAP_ATTACH_PID \
    FM_HERDR_LAB_BOOTSTRAP_ATTACH_START \
    FM_HERDR_LAB_BOOTSTRAP_OWNER \
    FM_HERDR_LAB_BOOTSTRAP_PANE < "$record" || return 1
  extra=$(sed -n '2p' "$record")
  [ -z "$extra" ] \
    && [ "$FM_HERDR_LAB_BOOTSTRAP_SESSION" = "$name" ] \
    && [[ "$FM_HERDR_LAB_BOOTSTRAP_PID" =~ ^[0-9]+$ ]] \
    && [[ "$FM_HERDR_LAB_BOOTSTRAP_START" =~ ^[0-9]+$ ]] \
    && [[ "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_PID" =~ ^[0-9]+$ ]] \
    && [[ "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_START" =~ ^[0-9]+$ ]] \
    && [[ "$FM_HERDR_LAB_BOOTSTRAP_OWNER" =~ ^fm-herdr-lab:${name}:[0-9]+:[0-9]+:[0-9]+$ ]] \
    && [ "$FM_HERDR_LAB_BOOTSTRAP_PID" -gt 1 ] \
    && [ "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_PID" -gt 1 ] \
    && [ "$FM_HERDR_LAB_BOOTSTRAP_PID" != "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_PID" ] || {
      fm_herdr_lab_error "bootstrap client state for '$name' is malformed or mismatched"
      return 1
    }
}

fm_herdr_lab_process_is_owned() { # <pid> <start> <owner>
  local current
  current=$(fm_herdr_lab_process_start "$1" 2>/dev/null) || return 1
  [ "$current" = "$2" ] && fm_herdr_lab_process_has_owner "$1" "$3"
}

fm_herdr_lab_require_bootstrap_processes() { # uses FM_HERDR_LAB_BOOTSTRAP_*
  fm_herdr_lab_process_is_owned \
    "$FM_HERDR_LAB_BOOTSTRAP_PID" "$FM_HERDR_LAB_BOOTSTRAP_START" "$FM_HERDR_LAB_BOOTSTRAP_OWNER" \
    && fm_herdr_lab_process_is_owned \
      "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_PID" "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_START" "$FM_HERDR_LAB_BOOTSTRAP_OWNER" \
    || {
      fm_herdr_lab_error "bootstrap client process ownership is stale or mismatched"
      return 1
    }
}

fm_herdr_lab_stop_recorded_process() { # <pid> <start> <owner> <label>
  local pid=$1 start=$2 owner=$3 label=$4 attempt=0 current
  [ -e "/proc/$pid" ] || return 0
  fm_herdr_lab_process_is_owned "$pid" "$start" "$owner" || {
    fm_herdr_lab_error "$label PID $pid has stale or mismatched ownership"
    return 1
  }
  kill -TERM "$pid" 2>/dev/null || {
    [ ! -e "/proc/$pid" ] && return 0
    fm_herdr_lab_error "could not stop $label PID $pid"
    return 1
  }
  while [ "$attempt" -lt 50 ]; do
    [ -e "/proc/$pid" ] || return 0
    current=$(fm_herdr_lab_process_start "$pid" 2>/dev/null) || return 0
    [ "$current" = "$start" ] || {
      fm_herdr_lab_error "$label PID $pid changed identity while stopping"
      return 1
    }
    [ "$(fm_herdr_lab_process_state "$pid" 2>/dev/null)" != Z ] || return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  fm_herdr_lab_error "$label PID $pid did not stop after TERM"
  return 1
}

fm_herdr_lab_remove_bootstrap_record() { # <session>
  local name=$1 dir record log
  dir=$(fm_herdr_lab_bootstrap_dir "$name")
  record=$(fm_herdr_lab_bootstrap_record_path "$name")
  log=$(fm_herdr_lab_bootstrap_log_path "$name")
  rm -f "$record" "$log" || return 1
  rmdir "$dir" 2>/dev/null || {
    fm_herdr_lab_error "bootstrap client state directory for '$name' contains unexpected state"
    return 1
  }
}

fm_herdr_lab_stop_bootstrap_client() { # <session>
  local name=$1 dir
  dir=$(fm_herdr_lab_bootstrap_dir "$name")
  [ ! -e "$dir" ] && [ ! -L "$dir" ] && return 0
  fm_herdr_lab_read_bootstrap_record "$name" || return 1
  fm_herdr_lab_stop_recorded_process \
    "$FM_HERDR_LAB_BOOTSTRAP_PID" \
    "$FM_HERDR_LAB_BOOTSTRAP_START" \
    "$FM_HERDR_LAB_BOOTSTRAP_OWNER" \
    "bootstrap client" || return 1
  wait "$FM_HERDR_LAB_BOOTSTRAP_PID" 2>/dev/null || true
  fm_herdr_lab_stop_recorded_process \
    "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_PID" \
    "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_START" \
    "$FM_HERDR_LAB_BOOTSTRAP_OWNER" \
    "bootstrap PTY child" || return 1
  fm_herdr_lab_remove_bootstrap_record "$name"
}

fm_herdr_lab_require_owned_running() { # <session>
  local name=$1 tripwire sessions identity
  fm_herdr_lab_validate_name "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] && [ ! -L "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; provision it before bootstrap-pane"
    return 1
  }
  fm_herdr_lab_check_tripwire "$name" || return 1
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot read Herdr sessions before bootstrap-pane"
    return 1
  }
  identity=$(printf '%s' "$sessions" | jq -er --arg name "$name" '
    [.sessions[]? | select(.name == $name)]
    | select(length == 1)
    | .[0]
    | select(.default == false and .running == true)
    | .name
  ' 2>/dev/null) || {
    fm_herdr_lab_error "bootstrap-pane requires exactly one owned running non-default session named '$name'"
    return 1
  }
  [ "$identity" = "$name" ] || {
    fm_herdr_lab_error "bootstrap-pane session identity mismatch for '$name'"
    return 1
  }
}

fm_herdr_lab_bootstrap_pane() { # <session>
  local name=$1 dir log panes pane_count pane client_pid client_start attach_pid attach_start owner command attempt
  local max_attempts=${FM_HERDR_LAB_BOOTSTRAP_MAX_ATTEMPTS:-100}
  fm_herdr_lab_require_owned_running "$name" || return 1
  command -v script >/dev/null 2>&1 || { fm_herdr_lab_error "script is required for bootstrap-pane"; return 1; }
  command -v setsid >/dev/null 2>&1 || { fm_herdr_lab_error "setsid is required for bootstrap-pane"; return 1; }
  command -v stty >/dev/null 2>&1 || { fm_herdr_lab_error "stty is required for bootstrap-pane"; return 1; }
  [ -r /proc/self/stat ] || { fm_herdr_lab_error "/proc process identity is required for bootstrap-pane"; return 1; }
  [[ "$max_attempts" =~ ^[0-9]+$ ]] && [ "$max_attempts" -ge 1 ] && [ "$max_attempts" -le 100 ] || {
    fm_herdr_lab_error "invalid bootstrap-pane wait bound"
    return 1
  }

  dir=$(fm_herdr_lab_bootstrap_dir "$name")
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    fm_herdr_lab_error "bootstrap client state already exists for '$name'; refusing ambiguous ownership"
    return 1
  fi

  panes=$(fm_herdr_lab_cli "$name" pane list 2>/dev/null) || {
    fm_herdr_lab_error "cannot inspect panes before bootstrap-pane"
    return 1
  }
  pane_count=$(printf '%s' "$panes" | jq -er '
    select((.result.panes | type) == "array") | (.result.panes | length)
  ' 2>/dev/null) || {
    fm_herdr_lab_error "pane inventory for '$name' is unreadable"
    return 1
  }
  [ "$pane_count" -eq 0 ] || {
    fm_herdr_lab_error "bootstrap-pane requires an owned zero-pane lab; '$name' has $pane_count pane(s)"
    return 1
  }

  mkdir "$dir" || {
    fm_herdr_lab_error "cannot claim bootstrap client ownership for '$name'"
    return 1
  }
  chmod 700 "$dir" || { rmdir "$dir"; return 1; }
  log=$(fm_herdr_lab_bootstrap_log_path "$name")
  owner="fm-herdr-lab:${name}:$$:${RANDOM}:${RANDOM}"
  command="unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID; stty rows 24 cols 80; exec herdr --session '$name'"
  HERDR_SESSION="$name" \
    FM_HERDR_LAB_BOOTSTRAP_OWNER="$owner" \
    TERM=xterm-256color \
    setsid script -q -e -c "$command" /dev/null > "$log" 2>&1 </dev/null &
  client_pid=$!

  attempt=0
  client_start=
  while [ "$attempt" -lt 20 ]; do
    client_start=$(fm_herdr_lab_process_start "$client_pid" 2>/dev/null || true)
    [ -n "$client_start" ] && break
    kill -0 "$client_pid" 2>/dev/null || break
    sleep 0.01
    attempt=$((attempt + 1))
  done
  if [ -z "$client_start" ] \
     || ! fm_herdr_lab_process_has_owner "$client_pid" "$owner"; then
    kill -TERM "$client_pid" 2>/dev/null || true
    wait "$client_pid" 2>/dev/null || true
    rm -f "$log"
    rmdir "$dir" 2>/dev/null || true
    fm_herdr_lab_error "bootstrap client for '$name' did not start with a verifiable owner identity"
    return 1
  fi

  attempt=0
  attach_pid=
  attach_start=
  while [ "$attempt" -lt "$max_attempts" ]; do
    attach_pid=$(fm_herdr_lab_single_child_pid "$client_pid" 2>/dev/null || true)
    if [ -n "$attach_pid" ]; then
      attach_start=$(fm_herdr_lab_process_start "$attach_pid" 2>/dev/null || true)
      if [ -n "$attach_start" ] \
         && fm_herdr_lab_process_has_owner "$attach_pid" "$owner"; then
        break
      fi
    fi
    kill -0 "$client_pid" 2>/dev/null || break
    attach_pid=
    attach_start=
    sleep 0.01
    attempt=$((attempt + 1))
  done
  if [ -z "$attach_pid" ] || [ -z "$attach_start" ]; then
    kill -TERM "$client_pid" 2>/dev/null || true
    wait "$client_pid" 2>/dev/null || true
    rm -f "$log"
    rmdir "$dir" 2>/dev/null || true
    fm_herdr_lab_error "bootstrap client for '$name' did not expose one verifiable PTY child"
    return 1
  fi
  fm_herdr_lab_write_bootstrap_record \
    "$name" "$client_pid" "$client_start" "$attach_pid" "$attach_start" "$owner" || {
      kill -TERM "$client_pid" 2>/dev/null || true
      wait "$client_pid" 2>/dev/null || true
      rm -f "$log"
      rmdir "$dir" 2>/dev/null || true
      return 1
    }
  fm_herdr_lab_read_bootstrap_record "$name" || {
    fm_herdr_lab_stop_bootstrap_client "$name" \
      || fm_herdr_lab_error "could not clean bootstrap client after a state-read failure"
    return 1
  }

  attempt=0
  while [ "$attempt" -lt "$max_attempts" ]; do
    fm_herdr_lab_require_bootstrap_processes >/dev/null 2>&1 || break
    panes=$(fm_herdr_lab_cli "$name" pane list 2>/dev/null) || panes=
    pane_count=$(printf '%s' "$panes" | jq -er '
      select((.result.panes | type) == "array") | (.result.panes | length)
    ' 2>/dev/null || true)
    case "$pane_count" in
      0|'') ;;
      1)
        pane=$(printf '%s' "$panes" | jq -er '
          .result.panes[0].pane_id | select(type == "string" and length > 0)
        ' 2>/dev/null || true)
        [ -n "$pane" ] && break
        ;;
      *)
        fm_herdr_lab_error "bootstrap-pane created an ambiguous $pane_count-pane inventory in '$name'"
        break
        ;;
    esac
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if [ -z "${pane:-}" ]; then
    fm_herdr_lab_stop_bootstrap_client "$name" \
      || fm_herdr_lab_error "could not clean bootstrap client after pane wait failure"
    fm_herdr_lab_error "lab session '$name' did not produce exactly one bootstrap pane within 10 seconds"
    return 1
  fi
  fm_herdr_lab_write_bootstrap_record \
    "$name" "$client_pid" "$client_start" "$attach_pid" "$attach_start" "$owner" "$pane" || {
    fm_herdr_lab_stop_bootstrap_client "$name" \
      || fm_herdr_lab_error "could not clean bootstrap client after state write failure"
    return 1
  }
  jq -nc --arg session "$name" --arg pane_id "$pane" --argjson client_pid "$client_pid" \
    '{session:$session,pane_id:$pane_id,client_pid:$client_pid}'
}

fm_herdr_lab_stop() { # <session>
  local name=$1 tripwire sessions running
  fm_herdr_lab_validate_name "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] && [ ! -L "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing stop"
    return 1
  }
  fm_herdr_lab_check_tripwire "$name" || return 1
  fm_herdr_lab_stop_bootstrap_client "$name" || return 1
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "refusing stop because session list failed"
    return 1
  }
  running=$(printf '%s' "$sessions" | jq -r --arg name "$name" '
    [.sessions[]? | select(.name == $name)]
    | select(length == 1)
    | .[0]
    | select(.default == false)
    | .running
  ' 2>/dev/null) || {
    fm_herdr_lab_error "refusing stop for '$name': session is absent, ambiguous, or default"
    return 1
  }
  case "$running" in
    true) fm_herdr_lab_raw "$name" session stop "$name" --json ;;
    false) : ;;
    *) fm_herdr_lab_error "refusing stop for '$name': running state is ambiguous"; return 1 ;;
  esac
  fm_herdr_lab_check_tripwire "$name"
}

fm_herdr_lab_teardown() { # <session>
  local name=$1 tripwire sessions delete_status=0
  fm_herdr_lab_validate_name "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] && [ ! -L "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing destructive calls"
    return 1
  }
  fm_herdr_lab_check_tripwire "$name" || return 1
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before teardown"
    return 1
  }
  if ! printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    fm_herdr_lab_stop_bootstrap_client "$name" || return 1
    fm_herdr_lab_verify_tripwire "$name"
    return
  fi
  fm_herdr_lab_stop "$name" >/dev/null || return 1
  sleep 0.5
  fm_herdr_lab_refuse_if_default "$name" || return 1
  fm_herdr_lab_raw "$name" session delete "$name" --json >/dev/null 2>&1 || delete_status=$?
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot confirm removal of lab session '$name' after teardown"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    if [ "$delete_status" -ne 0 ]; then
      fm_herdr_lab_error "session delete failed for '$name' and the lab session remains"
    else
      fm_herdr_lab_error "lab session '$name' remains after teardown"
    fi
    return 1
  fi
  fm_herdr_lab_verify_tripwire "$name"
}

fm_herdr_lab_name() { # <label>
  local label=${1:-lab}
  label=$(printf '%s' "$label" | tr -cd 'a-zA-Z0-9_-' | sed 's/^[^a-zA-Z0-9]*//; s/-*$//')
  [ -n "$label" ] || label=lab
  label=${label:0:16}
  label=${label%-}
  [ -n "$label" ] || label=lab
  printf 'fm-lab-%s-%s-%s\n' "$label" "$$" "$RANDOM"
}

fm_herdr_lab_usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fm_herdr_lab_main() {
  local command=${1:-}
  case "$command" in
    name)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_name "$2"
      ;;
    prepare)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_prepare "$2"
      ;;
    provision)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_provision "$2"
      ;;
    bootstrap-pane)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_bootstrap_pane "$2"
      ;;
    run)
      [ "$#" -ge 3 ] || { fm_herdr_lab_usage >&2; return 2; }
      shift
      fm_herdr_lab_cli "$@"
      ;;
    stop)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_stop "$2"
      ;;
    teardown)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_teardown "$2"
      ;;
    -h|--help|help)
      fm_herdr_lab_usage
      ;;
    *)
      fm_herdr_lab_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -e
  fm_herdr_lab_main "$@"
fi
