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
# Both paths pass the provisioned server's authoritative generation immediately
# before the exact trailing --session on each destructive call.
# Provision records the running default session as a fleet-state tripwire and
# teardown requires that record to be identical afterward.
# Provision records the helper-owned server's machine-readable generation.
# Prepare is a compatibility alias for the same guarded provisioning path.
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

fm_herdr_lab_identity_path() { # <session>
  printf '%s/%s.session-identity.json' "$(fm_herdr_lab_state_dir)" "$1"
}

fm_herdr_lab_claim_path() { # <session>
  printf '%s/%s.session-claim.json' "$(fm_herdr_lab_state_dir)" "$1"
}

fm_herdr_lab_lifecycle_lock_path() { # <session>
  printf '%s/%s.lifecycle.lock' "$(fm_herdr_lab_state_dir)" "$1"
}

fm_herdr_lab_stop_receipt_path() { # <session>
  printf '%s/%s.stop-generation.json' "$(fm_herdr_lab_state_dir)" "$1"
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

fm_herdr_lab_read_lifecycle_lock() { # <session>; sets FM_HERDR_LAB_LOCK_RECORD_*
  local name=$1 lock record extra
  lock=$(fm_herdr_lab_lifecycle_lock_path "$name")
  [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
  record=$(sed -n '1p' "$lock" 2>/dev/null) || return 1
  extra=$(sed -n '2p' "$lock" 2>/dev/null) || return 1
  [ -n "$record" ] && [ -z "$extra" ] || return 1
  IFS=$'\t' read -r FM_HERDR_LAB_LOCK_RECORD_NAME FM_HERDR_LAB_LOCK_RECORD_PID FM_HERDR_LAB_LOCK_RECORD_START FM_HERDR_LAB_LOCK_RECORD_OWNER <<< "$record" || return 1
  [ "$FM_HERDR_LAB_LOCK_RECORD_NAME" = "$name" ] || return 1
  [[ "$FM_HERDR_LAB_LOCK_RECORD_PID" =~ ^[0-9]+$ ]] || return 1
  [ "$FM_HERDR_LAB_LOCK_RECORD_PID" -gt 1 ] || return 1
  [ -n "$FM_HERDR_LAB_LOCK_RECORD_START" ] || return 1
  [[ "$FM_HERDR_LAB_LOCK_RECORD_OWNER" =~ ^fm-herdr-lab-lock:${name}:[0-9]+:[0-9]+$ ]] || return 1
}

fm_herdr_lab_lifecycle_lock_live() { # <session>
  local name=$1 current state
  fm_herdr_lab_read_lifecycle_lock "$name" || return 1
  state=$(fm_herdr_lab_process_state "$FM_HERDR_LAB_LOCK_RECORD_PID" 2>/dev/null || true)
  case "$state" in
    Z*) return 1 ;;
    '') return 1 ;;
  esac
  kill -0 "$FM_HERDR_LAB_LOCK_RECORD_PID" 2>/dev/null || return 1
  current=$(fm_herdr_lab_process_start "$FM_HERDR_LAB_LOCK_RECORD_PID" 2>/dev/null || true)
  [ -n "$current" ] && [ "$current" = "$FM_HERDR_LAB_LOCK_RECORD_START" ]
}

fm_herdr_lab_lifecycle_lock_stale() { # <session>
  local name=$1 current state
  fm_herdr_lab_read_lifecycle_lock "$name" || return 1
  state=$(fm_herdr_lab_process_state "$FM_HERDR_LAB_LOCK_RECORD_PID" 2>/dev/null || true)
  case "$state" in
    Z*) return 0 ;;
    '') return 1 ;;
  esac
  if kill -0 "$FM_HERDR_LAB_LOCK_RECORD_PID" 2>/dev/null; then
    current=$(fm_herdr_lab_process_start "$FM_HERDR_LAB_LOCK_RECORD_PID" 2>/dev/null || true)
    [ -n "$current" ] && [ "$current" != "$FM_HERDR_LAB_LOCK_RECORD_START" ] || return 1
  fi
}

fm_herdr_lab_read_lifecycle_reclaim() { # <session>; sets FM_HERDR_LAB_RECLAIM_*
  local name=$1 claim record extra
  claim=$(fm_herdr_lab_lifecycle_lock_path "$name").reclaim
  [ -f "$claim" ] && [ ! -L "$claim" ] || return 1
  record=$(sed -n '1p' "$claim" 2>/dev/null) || return 1
  extra=$(sed -n '2p' "$claim" 2>/dev/null) || return 1
  [ -n "$record" ] && [ -z "$extra" ] || return 1
  IFS=$'\t' read -r FM_HERDR_LAB_RECLAIM_NAME FM_HERDR_LAB_RECLAIM_PID FM_HERDR_LAB_RECLAIM_START FM_HERDR_LAB_RECLAIM_OWNER <<< "$record" || return 1
  [ "$FM_HERDR_LAB_RECLAIM_NAME" = "$name" ] || return 1
  [[ "$FM_HERDR_LAB_RECLAIM_PID" =~ ^[0-9]+$ ]] || return 1
  [ "$FM_HERDR_LAB_RECLAIM_PID" -gt 1 ] || return 1
  [ -n "$FM_HERDR_LAB_RECLAIM_START" ] || return 1
  [[ "$FM_HERDR_LAB_RECLAIM_OWNER" =~ ^fm-herdr-lab-reclaim:${name}:[0-9]+:[0-9]+$ ]] || return 1
}

fm_herdr_lab_lifecycle_reclaim_stale() { # <session>
  local name=$1 current state
  fm_herdr_lab_read_lifecycle_reclaim "$name" || return 1
  state=$(fm_herdr_lab_process_state "$FM_HERDR_LAB_RECLAIM_PID" 2>/dev/null || true)
  case "$state" in
    Z*) return 0 ;;
    '') return 1 ;;
  esac
  if kill -0 "$FM_HERDR_LAB_RECLAIM_PID" 2>/dev/null; then
    current=$(fm_herdr_lab_process_start "$FM_HERDR_LAB_RECLAIM_PID" 2>/dev/null || true)
    [ -n "$current" ] && [ "$current" != "$FM_HERDR_LAB_RECLAIM_START" ] || return 1
  fi
}

fm_herdr_lab_reclaim_lifecycle_lock() { # <session>
  local name=$1 lock stale claim stale_claim status=1 claim_pid claim_start claim_owner claim_tmp current_pid
  lock=$(fm_herdr_lab_lifecycle_lock_path "$name")
  claim="$lock.reclaim"
  if [ -e "$claim" ] || [ -L "$claim" ]; then
    fm_herdr_lab_lifecycle_reclaim_stale "$name" || return 1
    stale_claim="$claim.stale.${BASHPID:-$$}.$RANDOM"
    mv "$claim" "$stale_claim" 2>/dev/null || return 1
    rm -f "$stale_claim" || return 1
  fi
  current_pid=${BASHPID:-$$}
  claim_pid=$current_pid
  claim_start=$(fm_herdr_lab_process_start "$claim_pid" 2>/dev/null || true)
  [ -n "$claim_start" ] || return 1
  claim_owner="fm-herdr-lab-reclaim:${name}:${claim_pid}:$RANDOM"
  claim_tmp="$claim.tmp.${claim_pid}.$RANDOM"
  (umask 077; printf '%s\t%s\t%s\t%s\n' "$name" "$claim_pid" "$claim_start" "$claim_owner" > "$claim_tmp") || {
    rm -f "$claim_tmp"
    return 1
  }
  if ! ln "$claim_tmp" "$claim" 2>/dev/null; then
    rm -f "$claim_tmp"
    return 1
  fi
  rm -f "$claim_tmp"
  fm_herdr_lab_read_lifecycle_reclaim "$name" || return 1
  [ "$FM_HERDR_LAB_RECLAIM_PID" = "$claim_pid" ] && [ "$FM_HERDR_LAB_RECLAIM_START" = "$claim_start" ] && [ "$FM_HERDR_LAB_RECLAIM_OWNER" = "$claim_owner" ] || return 1
  if [ -f "$lock" ] && [ ! -L "$lock" ]; then
    if fm_herdr_lab_lifecycle_lock_stale "$name"; then
      stale="$lock.stale.${BASHPID:-$$}.$RANDOM"
      mv "$lock" "$stale" 2>/dev/null && rm -f "$stale"
      status=$?
    fi
  elif [ -d "$lock" ] && [ ! -L "$lock" ]; then
    status=1
  else
    status=0
  fi
  if fm_herdr_lab_read_lifecycle_reclaim "$name" && [ "$FM_HERDR_LAB_RECLAIM_PID" = "$claim_pid" ] && [ "$FM_HERDR_LAB_RECLAIM_START" = "$claim_start" ] && [ "$FM_HERDR_LAB_RECLAIM_OWNER" = "$claim_owner" ]; then
    rm -f "$claim" || status=1
  else
    status=1
  fi
  return "$status"
}

fm_herdr_lab_lock_session() { # <session>
  local name=${1:-} state_dir lock claim depth lock_pid lock_start owner tmp tmp_name current_pid borrowed attempt=0
  fm_herdr_lab_validate_name "$name" || return 1
  current_pid=${BASHPID:-$$}
  if [ "${FM_HERDR_LAB_LOCK_NAME:-}" = "$name" ]; then
    fm_herdr_lab_read_lifecycle_lock "$name" || {
      fm_herdr_lab_error "lifecycle lock for '$name' is absent or malformed"
      return 1
    }
    if [ "${FM_HERDR_LAB_LOCK_PID:-}" = "$current_pid" ]; then
      [ "$FM_HERDR_LAB_LOCK_RECORD_PID" = "$FM_HERDR_LAB_LOCK_PID" ] && [ "$FM_HERDR_LAB_LOCK_RECORD_START" = "${FM_HERDR_LAB_LOCK_START:-}" ] && [ "$FM_HERDR_LAB_LOCK_RECORD_OWNER" = "${FM_HERDR_LAB_LOCK_OWNER:-}" ] || {
        fm_herdr_lab_error "lifecycle lock ownership changed for '$name'"
        return 1
      }
      depth=${FM_HERDR_LAB_LOCK_DEPTH:-1}
      FM_HERDR_LAB_LOCK_DEPTH=$((depth + 1))
      return 0
    fi
    [ "$FM_HERDR_LAB_LOCK_RECORD_PID" = "${FM_HERDR_LAB_LOCK_PID:-}" ] && [ "$FM_HERDR_LAB_LOCK_RECORD_START" = "${FM_HERDR_LAB_LOCK_START:-}" ] && [ "$FM_HERDR_LAB_LOCK_RECORD_OWNER" = "${FM_HERDR_LAB_LOCK_OWNER:-}" ] || {
      fm_herdr_lab_error "lifecycle lock ownership changed for '$name'"
      return 1
    }
    borrowed=${FM_HERDR_LAB_LOCK_BORROWED_DEPTH:-0}
    FM_HERDR_LAB_LOCK_BORROWED_DEPTH=$((borrowed + 1))
    return 0
  fi
  [ -z "${FM_HERDR_LAB_LOCK_NAME:-}" ] || {
    fm_herdr_lab_error "another named session lifecycle lock is already held"
    return 1
  }
  state_dir=$(fm_herdr_lab_state_dir)
  mkdir -p "$state_dir" || {
    fm_herdr_lab_error "could not prepare the lifecycle lock directory"
    return 1
  }
  lock=$(fm_herdr_lab_lifecycle_lock_path "$name")
  lock_pid=$current_pid
  lock_start=$(fm_herdr_lab_process_start "$lock_pid" 2>/dev/null || true)
  [ -n "$lock_start" ] || {
    fm_herdr_lab_error "could not identify the lifecycle lock owner for '$name'"
    return 1
  }
  owner="fm-herdr-lab-lock:${name}:${lock_pid}:$RANDOM"
  claim="$lock.reclaim"
  while [ "$attempt" -lt 3 ]; do
    if [ -e "$claim" ] || [ -L "$claim" ]; then
      if fm_herdr_lab_reclaim_lifecycle_lock "$name"; then
        attempt=$((attempt + 1))
        continue
      fi
      fm_herdr_lab_error "stale lifecycle lock recovery for '$name' is already in progress or ambiguous"
      return 1
    fi
    tmp="$state_dir/.${name}.lifecycle.lock.tmp.${lock_pid}.$RANDOM"
    tmp_name=${tmp##*/}
    (umask 077; printf '%s\t%s\t%s\t%s\n' "$name" "$lock_pid" "$lock_start" "$owner" > "$tmp") || {
      rm -f "$tmp"
      fm_herdr_lab_error "could not prepare the lifecycle lock for '$name'"
      return 1
    }
    if [ ! -e "$lock" ] && [ ! -L "$lock" ] && ln "$tmp" "$lock" 2>/dev/null; then
      if [ -f "$lock" ] && [ ! -L "$lock" ]; then
        rm -f "$tmp"
        fm_herdr_lab_read_lifecycle_lock "$name" || {
          fm_herdr_lab_error "lifecycle lock for '$name' was not recorded safely"
          return 1
        }
        [ "$FM_HERDR_LAB_LOCK_RECORD_PID" = "$lock_pid" ] && [ "$FM_HERDR_LAB_LOCK_RECORD_START" = "$lock_start" ] && [ "$FM_HERDR_LAB_LOCK_RECORD_OWNER" = "$owner" ] || {
          fm_herdr_lab_error "lifecycle lock for '$name' was replaced during acquisition"
          return 1
        }
        FM_HERDR_LAB_LOCK_NAME=$name
        FM_HERDR_LAB_LOCK_PID=$lock_pid
        FM_HERDR_LAB_LOCK_START=$lock_start
        FM_HERDR_LAB_LOCK_OWNER=$owner
        FM_HERDR_LAB_LOCK_DEPTH=1
        FM_HERDR_LAB_LOCK_BORROWED_DEPTH=0
        return 0
      fi
      if [ -d "$lock" ] && [ ! -L "$lock" ]; then
        rm -f "$lock/$tmp_name" 2>/dev/null || true
      fi
    fi
    rm -f "$tmp"
    if fm_herdr_lab_lifecycle_lock_live "$name"; then
      fm_herdr_lab_error "lifecycle operation for '$name' is already in progress"
      return 1
    fi
    if fm_herdr_lab_reclaim_lifecycle_lock "$name"; then
      attempt=$((attempt + 1))
      continue
    fi
    if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
      attempt=$((attempt + 1))
      continue
    fi
    fm_herdr_lab_error "lifecycle lock for '$name' is stale or ambiguous"
    return 1
  done
  fm_herdr_lab_error "could not acquire the lifecycle lock for '$name'"
  return 1
}

fm_herdr_lab_unlock_session() { # <session>
  local name=${1:-} lock depth current_pid borrowed
  [ "${FM_HERDR_LAB_LOCK_NAME:-}" = "$name" ] || {
    fm_herdr_lab_error "lifecycle lock ownership mismatch for '$name'"
    return 1
  }
  current_pid=${BASHPID:-$$}
  if [ "${FM_HERDR_LAB_LOCK_PID:-}" != "$current_pid" ]; then
    borrowed=${FM_HERDR_LAB_LOCK_BORROWED_DEPTH:-0}
    [ "$borrowed" -gt 0 ] || {
      fm_herdr_lab_error "lifecycle lock ownership mismatch for '$name'"
      return 1
    }
    if [ "$borrowed" -gt 1 ]; then
      FM_HERDR_LAB_LOCK_BORROWED_DEPTH=$((borrowed - 1))
    else
      unset FM_HERDR_LAB_LOCK_BORROWED_DEPTH
    fi
    return 0
  fi
  depth=${FM_HERDR_LAB_LOCK_DEPTH:-0}
  [ "$depth" -gt 1 ] && {
    FM_HERDR_LAB_LOCK_DEPTH=$((depth - 1))
    return 0
  }
  fm_herdr_lab_read_lifecycle_lock "$name" || {
    fm_herdr_lab_error "lifecycle lock for '$name' is absent or malformed"
    return 1
  }
  [ "$FM_HERDR_LAB_LOCK_RECORD_PID" = "${FM_HERDR_LAB_LOCK_PID:-}" ] && [ "$FM_HERDR_LAB_LOCK_RECORD_START" = "${FM_HERDR_LAB_LOCK_START:-}" ] && [ "$FM_HERDR_LAB_LOCK_RECORD_OWNER" = "${FM_HERDR_LAB_LOCK_OWNER:-}" ] || {
    fm_herdr_lab_error "lifecycle lock ownership changed for '$name'"
    return 1
  }
  lock=$(fm_herdr_lab_lifecycle_lock_path "$name")
  rm -f "$lock" || {
    fm_herdr_lab_error "could not release the lifecycle lock for '$name'"
    return 1
  }
  unset FM_HERDR_LAB_LOCK_NAME FM_HERDR_LAB_LOCK_PID FM_HERDR_LAB_LOCK_START FM_HERDR_LAB_LOCK_OWNER FM_HERDR_LAB_LOCK_DEPTH FM_HERDR_LAB_LOCK_BORROWED_DEPTH
}

fm_herdr_lab_raw() { # <session> <herdr arguments...>
  local name=$1
  shift
  herdr "$@" --session "$name"
}

fm_herdr_lab_validate_generation() { # <generation>
  [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

fm_herdr_lab_guarded_raw() { # <session> <generation> <herdr arguments...>
  local name=$1 generation=$2
  shift 2
  fm_herdr_lab_validate_generation "$generation" || {
    fm_herdr_lab_error "refusing a Herdr call with a malformed server generation"
    return 1
  }
  herdr "$@" --expected-generation "$generation" --session "$name"
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

fm_herdr_lab_session_snapshot() { # <session>
  local name=$1 sessions
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || return 1
  printf '%s' "$sessions" | jq -er --arg name "$name" '
    [.sessions[]? | select(.name == $name)]
    | select(length == 1)
    | .[0]
  ' 2>/dev/null
}

fm_herdr_lab_require_session_absent() { # <session>
  local name=$1 sessions count
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot verify that session '$name' is absent"
    return 1
  }
  count=$(printf '%s' "$sessions" | jq -er --arg name "$name" \
    '[.sessions[]? | select(.name == $name)] | length' 2>/dev/null) || return 1
  [ "$count" -eq 0 ] || {
    fm_herdr_lab_error "session '$name' appeared before the helper-owned server launch"
    return 1
  }
}

fm_herdr_lab_running_generation() { # <session> [expected-generation]
  local name=$1 expected=${2:-} output generation
  if [ -n "$expected" ]; then
    output=$(fm_herdr_lab_guarded_raw "$name" "$expected" status server --json 2>/dev/null) || return 1
  else
    output=$(fm_herdr_lab_raw "$name" status server --json 2>/dev/null) || return 1
  fi
  generation=$(printf '%s' "$output" | jq -ser --arg name "$name" '
    select(length == 1)
    | .[0]
    | select(type == "object")
    | select(.status == "running" and .running == true and .session == $name)
    | .generation
    | select(type == "string")
  ' 2>/dev/null) || return 1
  if [ -z "$generation" ] || ! fm_herdr_lab_validate_generation "$generation"; then
    fm_herdr_lab_error "server status for '$name' has no canonical generation"
    return 1
  fi
  [ -z "$expected" ] || [ "$generation" = "$expected" ] || {
    fm_herdr_lab_error "server status for '$name' returned a mismatched generation"
    return 1
  }
  printf '%s\n' "$generation"
}

fm_herdr_lab_write_session_claim() { # <session> <server-pid> <server-start> <owner>
  local name=$1 server_pid=$2 server_start=$3 owner=$4 claim tmp
  claim=$(fm_herdr_lab_claim_path "$name")
  [ -f "$claim" ] && [ ! -L "$claim" ] || return 1
  tmp="$claim.tmp.$$"
  (umask 077; jq -nc \
    --arg name "$name" \
    --argjson server_pid "$server_pid" \
    --arg server_start "$server_start" \
    --arg owner "$owner" \
    '{name:$name,server_pid:$server_pid,server_start:$server_start,owner:$owner}' \
    > "$tmp") || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$claim"
}

fm_herdr_lab_acquire_session_claim() { # <session>
  local name=$1 claim
  claim=$(fm_herdr_lab_claim_path "$name")
  [ ! -e "$claim" ] && [ ! -L "$claim" ] || {
    fm_herdr_lab_error "session creation claim for '$name' is already present"
    return 1
  }
  (umask 077; set -o noclobber; : > "$claim") 2>/dev/null || {
    fm_herdr_lab_error "could not atomically acquire the session creation claim for '$name'"
    return 1
  }
}

fm_herdr_lab_write_session_identity() { # <session> <generation> <server-pid> <server-start> <owner>
  local name=$1 generation=$2 server_pid=$3 server_start=$4 owner=$5 record tmp
  fm_herdr_lab_validate_generation "$generation" || return 1
  fm_herdr_lab_session_process_is_owned "$server_pid" "$server_start" "$owner" || {
    fm_herdr_lab_error "cannot bind '$name' to the helper-owned server launch"
    return 1
  }
  record=$(fm_herdr_lab_identity_path "$name")
  tmp="$record.tmp.$$"
  (umask 077; jq -nc \
    --arg name "$name" \
    --arg generation "$generation" \
    --argjson server_pid "$server_pid" \
    --arg server_start "$server_start" \
    --arg owner "$owner" \
    '{name:$name,generation:$generation,server_pid:$server_pid,server_start:$server_start,owner:$owner,state:"running"}' \
    > "$tmp") || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$record"
}

fm_herdr_lab_read_stop_receipt() { # <session>; sets FM_HERDR_LAB_STOP_*
  local name=$1 receipt identity
  receipt=$(fm_herdr_lab_stop_receipt_path "$name")
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || {
    fm_herdr_lab_error "stop generation receipt for '$name' is absent or ambiguous"
    return 1
  }
  identity=$(jq -ser '
    select(length == 1)
    | .[0]
    | select(type == "object")
    | select((.name | type) == "string")
    | select((.generation | type) == "string")
    | select((.state | type) == "string")
    | select(.state == "stopping" or .state == "stopped" or .state == "retired")
    | [.name,.generation,.state]
    | @tsv
  ' "$receipt" 2>/dev/null) || {
    fm_herdr_lab_error "stop generation receipt for '$name' is malformed"
    return 1
  }
  IFS=$'\t' read -r \
    FM_HERDR_LAB_STOP_NAME \
    FM_HERDR_LAB_STOP_GENERATION \
    FM_HERDR_LAB_STOP_STATE <<< "$identity"
  if [ "$FM_HERDR_LAB_STOP_NAME" != "$name" ] \
     || ! fm_herdr_lab_validate_generation "$FM_HERDR_LAB_STOP_GENERATION"; then
    fm_herdr_lab_error "stop generation receipt for '$name' is malformed or mismatched"
    return 1
  fi
}

fm_herdr_lab_retire_stopped_generation() { # <session>
  local name=$1 sessions named_count receipt tmp
  fm_herdr_lab_read_session_identity "$name" || return 1
  fm_herdr_lab_read_stop_receipt "$name" || return 1
  [ "$FM_HERDR_LAB_IDENTITY_STATE" = stopped ] \
    && [ "$FM_HERDR_LAB_STOP_GENERATION" = "$FM_HERDR_LAB_IDENTITY_GENERATION" ] || {
      fm_herdr_lab_error "cannot retire a mismatched stopped generation for '$name'"
      return 1
    }
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || return 1
  named_count=$(printf '%s' "$sessions" | jq -er --arg name "$name" \
    '[.sessions[]? | select(.name == $name)] | length' 2>/dev/null) || return 1
  [ "$named_count" -eq 0 ] || {
    fm_herdr_lab_error "stopped generation for '$name' was not deleted before retirement"
    return 1
  }
  if [ "$FM_HERDR_LAB_STOP_STATE" = retired ]; then
    return 0
  fi
  [ "$FM_HERDR_LAB_STOP_STATE" = stopped ] || {
    fm_herdr_lab_error "cannot retire a mismatched stopped generation for '$name'"
    return 1
  }
  receipt=$(fm_herdr_lab_stop_receipt_path "$name")
  tmp="$receipt.tmp.$$"
  (umask 077; jq -nc \
    --arg name "$name" \
    --arg generation "$FM_HERDR_LAB_STOP_GENERATION" \
    '{name:$name,generation:$generation,state:"retired"}' \
    > "$tmp") || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$receipt"
}

fm_herdr_lab_require_retired_session() { # <session>
  local name=$1
  fm_herdr_lab_read_session_identity "$name" || return 1
  fm_herdr_lab_read_stop_receipt "$name" || return 1
  if [ "$FM_HERDR_LAB_IDENTITY_STATE" != stopped ] \
     || [ "$FM_HERDR_LAB_STOP_STATE" != retired ] \
     || [ "$FM_HERDR_LAB_STOP_GENERATION" != "$FM_HERDR_LAB_IDENTITY_GENERATION" ] \
     || ! fm_herdr_lab_require_session_absent "$name"; then
    fm_herdr_lab_error "retired generation evidence for '$name' is absent or mismatched"
    return 1
  fi
}

fm_herdr_lab_begin_stop_receipt() { # <session>
  local name=$1 receipt tmp
  fm_herdr_lab_read_session_identity "$name" || return 1
  [ "$FM_HERDR_LAB_IDENTITY_STATE" = running ] || {
    fm_herdr_lab_error "named session identity for '$name' was not running before stop"
    return 1
  }
  receipt=$(fm_herdr_lab_stop_receipt_path "$name")
  if [ -e "$receipt" ] || [ -L "$receipt" ]; then
    fm_herdr_lab_read_stop_receipt "$name" || return 1
    if [ "$FM_HERDR_LAB_STOP_STATE" != stopping ] \
       || [ "$FM_HERDR_LAB_STOP_GENERATION" != "$FM_HERDR_LAB_IDENTITY_GENERATION" ]; then
      fm_herdr_lab_error "stop generation receipt for '$name' is stale or mismatched"
      return 1
    fi
    return 0
  fi
  tmp="$receipt.tmp.$$"
  (umask 077; jq -nc \
    --arg name "$name" \
    --arg generation "$FM_HERDR_LAB_IDENTITY_GENERATION" \
    '{name:$name,generation:$generation,state:"stopping"}' \
    > "$tmp") || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$receipt"
}

fm_herdr_lab_finish_stop_receipt() { # <session>
  local name=$1 snapshot running receipt tmp attempt=0
  fm_herdr_lab_read_session_identity "$name" || return 1
  fm_herdr_lab_read_stop_receipt "$name" || return 1
  [ "$FM_HERDR_LAB_STOP_STATE" = stopping ] \
    && [ "$FM_HERDR_LAB_STOP_GENERATION" = "$FM_HERDR_LAB_IDENTITY_GENERATION" ] || {
      fm_herdr_lab_error "stop generation receipt for '$name' does not bind the running server"
      return 1
    }
  while [ "$attempt" -lt 50 ]; do
    snapshot=$(fm_herdr_lab_session_snapshot "$name") || return 1
    running=$(printf '%s' "$snapshot" | jq -r --arg name "$name" '
      select(.name == $name and .default == false and (.running | type) == "boolean") | .running
    ' 2>/dev/null) || return 1
    case "$running" in true|false) ;; *) return 1 ;; esac
    [ "$running" = false ] && break
    sleep 0.1
    attempt=$((attempt + 1))
  done
  [ "$running" = false ] || {
    fm_herdr_lab_error "named session '$name' did not stop with its owned generation"
    return 1
  }
  receipt=$(fm_herdr_lab_stop_receipt_path "$name")
  tmp="$receipt.tmp.$$"
  (umask 077; jq -nc \
    --arg name "$name" \
    --arg generation "$FM_HERDR_LAB_STOP_GENERATION" \
    '{name:$name,generation:$generation,state:"stopped"}' \
    > "$tmp") || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$receipt"
}

fm_herdr_lab_stop_receipt_matches_identity() { # <session>
  local name=$1
  [ "$FM_HERDR_LAB_STOP_NAME" = "$name" ] \
    && [ "$FM_HERDR_LAB_STOP_GENERATION" = "$FM_HERDR_LAB_IDENTITY_GENERATION" ] || {
      fm_herdr_lab_error "stop generation receipt for '$name' does not bind the recorded server"
      return 1
    }
}

fm_herdr_lab_resume_stop_receipt() { # <session>
  local name=$1 snapshot running
  fm_herdr_lab_read_session_identity "$name" || return 1
  [ "$FM_HERDR_LAB_IDENTITY_STATE" = running ] || {
    fm_herdr_lab_error "named session identity for '$name' was not running during stop recovery"
    return 1
  }
  fm_herdr_lab_read_stop_receipt "$name" || return 1
  fm_herdr_lab_stop_receipt_matches_identity "$name" || return 1
  snapshot=$(fm_herdr_lab_session_snapshot "$name") || return 1
  running=$(printf '%s' "$snapshot" | jq -r '.running' 2>/dev/null) || return 1
  case "$running" in
    true)
      fm_herdr_lab_check_tripwire "$name" || return 1
      fm_herdr_lab_owned_raw "$name" true session stop "$name" --json || return 1
      ;;
    false) : ;;
    *) fm_herdr_lab_error "refusing stop recovery for '$name': running state is ambiguous"; return 1 ;;
  esac
  case "$FM_HERDR_LAB_STOP_STATE" in
    stopping) fm_herdr_lab_finish_stop_receipt "$name" || return 1 ;;
    stopped) : ;;
    *) fm_herdr_lab_error "stop generation receipt for '$name' is malformed or mismatched"; return 1 ;;
  esac
  fm_herdr_lab_check_tripwire "$name" || return 1
  fm_herdr_lab_write_stopped_session_identity "$name"
}

fm_herdr_lab_write_stopped_session_identity() { # <session>
  local name=$1 snapshot record tmp
  fm_herdr_lab_read_session_identity "$name" || return 1
  fm_herdr_lab_read_stop_receipt "$name" || return 1
  [ "$FM_HERDR_LAB_IDENTITY_STATE" = running ] || {
    fm_herdr_lab_error "named session identity for '$name' was not running before stop"
    return 1
  }
  [ "$FM_HERDR_LAB_STOP_STATE" = stopped ] \
    && [ "$FM_HERDR_LAB_STOP_GENERATION" = "$FM_HERDR_LAB_IDENTITY_GENERATION" ] || {
      fm_herdr_lab_error "stop generation receipt for '$name' does not bind the recorded server"
      return 1
    }
  snapshot=$(fm_herdr_lab_session_snapshot "$name") || {
    fm_herdr_lab_error "cannot read the stopped named session identity for '$name'"
    return 1
  }
  printf '%s' "$snapshot" | jq -e --arg name "$name" '
    .name == $name
    and .default == false
    and .running == false
  ' >/dev/null 2>&1 || {
    fm_herdr_lab_error "named session '$name' did not stop with its owned identity"
    return 1
  }
  record=$(fm_herdr_lab_identity_path "$name")
  tmp="$record.tmp.$$"
  (umask 077; jq -nc \
    --arg name "$name" \
    --arg generation "$FM_HERDR_LAB_IDENTITY_GENERATION" \
    --argjson server_pid "$FM_HERDR_LAB_IDENTITY_SERVER_PID" \
    --arg server_start "$FM_HERDR_LAB_IDENTITY_SERVER_START" \
    --arg owner "$FM_HERDR_LAB_IDENTITY_OWNER" \
    '{name:$name,generation:$generation,server_pid:$server_pid,server_start:$server_start,owner:$owner,state:"stopped"}' \
    > "$tmp") || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$record"
}

fm_herdr_lab_read_session_identity() { # <session>; sets FM_HERDR_LAB_IDENTITY_*
  local name=$1 record identity
  record=$(fm_herdr_lab_identity_path "$name")
  [ -f "$record" ] && [ ! -L "$record" ] || {
    fm_herdr_lab_error "named session identity for '$name' is absent or ambiguous"
    return 1
  }
  identity=$(jq -ser '
    select(length == 1)
    | .[0]
    | select(type == "object")
    | select((.name | type) == "string")
    | select((.generation | type) == "string")
    | select((.server_pid | type) == "number")
    | select((.server_start | type) == "string")
    | select((.owner | type) == "string")
    | select((.state | type) == "string")
    | select(.state == "running" or .state == "stopped")
    | [.name,.generation,.server_pid,.server_start,.owner,.state]
    | @tsv
  ' "$record" 2>/dev/null) || {
    fm_herdr_lab_error "named session identity for '$name' is malformed"
    return 1
  }
  IFS=$'\t' read -r \
    FM_HERDR_LAB_IDENTITY_NAME \
    FM_HERDR_LAB_IDENTITY_GENERATION \
    FM_HERDR_LAB_IDENTITY_SERVER_PID \
    FM_HERDR_LAB_IDENTITY_SERVER_START \
    FM_HERDR_LAB_IDENTITY_OWNER \
    FM_HERDR_LAB_IDENTITY_STATE <<< "$identity"
  if [ "$FM_HERDR_LAB_IDENTITY_NAME" != "$name" ] \
     || ! fm_herdr_lab_validate_generation "$FM_HERDR_LAB_IDENTITY_GENERATION" \
     || ! [[ "$FM_HERDR_LAB_IDENTITY_SERVER_PID" =~ ^[0-9]+$ ]] \
     || [ "$FM_HERDR_LAB_IDENTITY_SERVER_PID" -le 1 ] \
     || [ -z "$FM_HERDR_LAB_IDENTITY_SERVER_START" ] \
     || ! [[ "$FM_HERDR_LAB_IDENTITY_OWNER" =~ ^fm-herdr-lab-session:${name}:[0-9]+:[0-9]+:[0-9]+$ ]]; then
    fm_herdr_lab_error "named session identity for '$name' is malformed or mismatched"
    return 1
  fi
}

fm_herdr_lab_require_owned_session() { # <session> <true|false|any>
  local name=$1 expected=${2:-any} snapshot running
  fm_herdr_lab_validate_name "$name" || return 1
  case "$expected" in
    true|false|any) ;;
    *) fm_herdr_lab_error "invalid named-session ownership state"; return 1 ;;
  esac
  fm_herdr_lab_read_session_identity "$name" || return 1
  [ "$FM_HERDR_LAB_IDENTITY_NAME" = "$name" ] || {
    fm_herdr_lab_error "named session identity mismatch for '$name'"
    return 1
  }
  snapshot=$(fm_herdr_lab_session_snapshot "$name") || {
    fm_herdr_lab_error "cannot read Herdr sessions while verifying '$name'"
    return 1
  }
  printf '%s' "$snapshot" | jq -e --arg name "$name" \
    '.name == $name and .default == false and (.running | type) == "boolean"' \
    >/dev/null 2>&1 || {
      fm_herdr_lab_error "named session '$name' is absent, ambiguous, default, or mismatched"
      return 1
    }
  running=$(printf '%s' "$snapshot" | jq -r '.running' 2>/dev/null) || return 1
  case "$expected" in
    true|false)
      [ "$running" = "$expected" ] || {
        fm_herdr_lab_error "named session '$name' has unexpected running state"
        return 1
      }
      ;;
  esac
  if [ "$running" = true ]; then
    [ "$FM_HERDR_LAB_IDENTITY_STATE" = running ] || {
      fm_herdr_lab_error "named session '$name' became running without its recorded helper-owned server"
      return 1
    }
    fm_herdr_lab_running_generation "$name" "$FM_HERDR_LAB_IDENTITY_GENERATION" >/dev/null || {
      fm_herdr_lab_error "named session server generation changed for '$name'"
      return 1
    }
  else
    [ "$FM_HERDR_LAB_IDENTITY_STATE" = stopped ] || {
      fm_herdr_lab_error "named session '$name' stopped without a helper-owned stop receipt"
      return 1
    }
    fm_herdr_lab_read_stop_receipt "$name" || return 1
    [ "$FM_HERDR_LAB_STOP_STATE" = stopped ] \
      && [ "$FM_HERDR_LAB_STOP_GENERATION" = "$FM_HERDR_LAB_IDENTITY_GENERATION" ] || {
        fm_herdr_lab_error "stopped named session generation receipt changed for '$name'"
        return 1
      }
  fi
  FM_HERDR_LAB_SESSION_RUNNING=$running
}

fm_herdr_lab_owned_raw_locked() { # <session> <true|false> <herdr arguments...>
  local name=$1 expected=$2 generation
  shift 2
  fm_herdr_lab_require_owned_session "$name" "$expected" || return 1
  generation=$FM_HERDR_LAB_IDENTITY_GENERATION
  fm_herdr_lab_guarded_raw "$name" "$generation" "$@"
}

fm_herdr_lab_owned_raw() { # <session> <true|false> <herdr arguments...>
  local name=${1:-} status
  fm_herdr_lab_lock_session "$name" || return 1
  fm_herdr_lab_owned_raw_locked "$@"
  status=$?
  fm_herdr_lab_unlock_session "$name" || status=1
  return "$status"
}

fm_herdr_lab_prepare_state() { # <session>
  local name=$1 claim_owned=${2:-0} sessions state_dir tripwire bootstrap_dir retiring
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
  bootstrap_dir=$(fm_herdr_lab_bootstrap_dir "$name")
  retiring="$bootstrap_dir.retiring.state"
  mkdir -p "$state_dir" || return 1
  [ ! -e "$tripwire" ] && [ ! -L "$tripwire" ] \
    && [ ! -e "$(fm_herdr_lab_identity_path "$name")" ] \
    && [ ! -L "$(fm_herdr_lab_identity_path "$name")" ] \
    && [ ! -e "$(fm_herdr_lab_stop_receipt_path "$name")" ] \
    && [ ! -L "$(fm_herdr_lab_stop_receipt_path "$name")" ] \
    && [ ! -e "$bootstrap_dir" ] && [ ! -L "$bootstrap_dir" ] \
    && [ ! -e "$retiring" ] && [ ! -L "$retiring" ] || {
    fm_herdr_lab_error "tripwire already exists for '$name'; refusing ambiguous ownership"
    return 1
  }
  if [ "$claim_owned" -eq 0 ]; then
    [ ! -e "$(fm_herdr_lab_claim_path "$name")" ] \
      && [ ! -L "$(fm_herdr_lab_claim_path "$name")" ] || {
        fm_herdr_lab_error "session creation claim for '$name' is already present"
        return 1
      }
  fi
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
      --session|--session=*|--expected-generation|--expected-generation=*)
        fm_herdr_lab_error "run forbids caller-supplied session or generation scope; the helper owns both"
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
  fm_herdr_lab_owned_raw "$name" true "$@"
}

fm_herdr_lab_run_locked() { # <session> <herdr arguments...>
  local name=$1
  shift
  fm_herdr_lab_require_owned_running "$name" || return 1
  fm_herdr_lab_cli "$name" "$@" || return 1
  fm_herdr_lab_check_tripwire "$name" || return 1
  fm_herdr_lab_require_owned_session "$name" true
}

fm_herdr_lab_run() { # <session> <herdr arguments...>
  local name=${1:-} status
  fm_herdr_lab_lock_session "$name" || return 1
  fm_herdr_lab_run_locked "$@"
  status=$?
  fm_herdr_lab_unlock_session "$name" || status=1
  return "$status"
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

fm_herdr_lab_clear_safe_claim() { # <session>
  local name=$1 claim
  claim=$(fm_herdr_lab_claim_path "$name")
  if fm_herdr_lab_require_session_absent "$name" >/dev/null 2>&1 \
     || fm_herdr_lab_require_owned_session "$name" false >/dev/null 2>&1; then
    rm -f "$claim"
  else
    fm_herdr_lab_error "retaining the session creation claim for '$name' because ownership is ambiguous"
    return 1
  fi
}

fm_herdr_lab_release_prelaunch_claim() { # <session> <owner>
  local name=$1 owner=$2 claim record
  claim=$(fm_herdr_lab_claim_path "$name")
  [ -f "$claim" ] && [ ! -L "$claim" ] || return 1
  if [ ! -s "$claim" ]; then
    rm -f "$claim"
    return $?
  fi
  record=$(jq -ser --arg name "$name" --arg owner "$owner" '
    select(length == 1)
    | .[0]
    | select(type == "object" and .name == $name and .server_pid == 0
      and .server_start == "pending" and .owner == $owner)
    | "pending"
  ' "$claim" 2>/dev/null) || return 1
  [ "$record" = pending ] || return 1
  rm -f "$claim"
}

fm_herdr_lab_abort_prelaunch() { # <session> <owner>
  local name=$1 owner=$2
  fm_herdr_lab_release_prelaunch_claim "$name" "$owner" || \
    fm_herdr_lab_error "retaining the session creation claim for '$name' because its ownership is ambiguous"
  return 1
}

fm_herdr_lab_require_no_bootstrap_evidence() { # <session>
  local name=$1 dir retired
  dir=$(fm_herdr_lab_bootstrap_dir "$name")
  retired="$dir.retiring.state"
  [ ! -e "$dir" ] && [ ! -L "$dir" ] \
    && [ ! -e "$retired" ] && [ ! -L "$retired" ] || {
      fm_herdr_lab_error "bootstrap client evidence for '$name' remains; refusing provisioning"
      return 1
    }
}

fm_herdr_lab_provision_locked() { # <session>
  local name=$1 sessions tripwire running generation attempt server_pid server_start owner claim stop_receipt max_attempts timeout_seconds named_count mode state_dir
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }

  state_dir=$(fm_herdr_lab_state_dir)
  mkdir -p "$state_dir" || return 1
  claim=$(fm_herdr_lab_claim_path "$name")
  fm_herdr_lab_acquire_session_claim "$name" || return 1
  owner="fm-herdr-lab-session:${name}:$$:${RANDOM}:${RANDOM}"
  fm_herdr_lab_write_session_claim "$name" 0 pending "$owner" || {
    fm_herdr_lab_release_prelaunch_claim "$name" "$owner" || \
      fm_herdr_lab_error "retaining the session creation claim for '$name' because its ownership is ambiguous"
    return 1
  }
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before provisioning '$name'"
    fm_herdr_lab_abort_prelaunch "$name" "$owner"
    return 1
  }
  named_count=$(printf '%s' "$sessions" | jq -er --arg name "$name" '[.sessions[]? | select(.name == $name)] | length' 2>/dev/null) || {
    fm_herdr_lab_error "cannot determine whether session '$name' already exists"
    fm_herdr_lab_abort_prelaunch "$name" "$owner"
    return 1
  }
  fm_herdr_lab_require_no_bootstrap_evidence "$name" || {
    fm_herdr_lab_abort_prelaunch "$name" "$owner"
    return 1
  }
  case "$named_count" in
    0)
      tripwire=$(fm_herdr_lab_tripwire_path "$name")
      if [ -e "$tripwire" ] || [ -L "$tripwire" ]; then
        if [ ! -f "$tripwire" ] || [ -L "$tripwire" ] \
           || ! fm_herdr_lab_retire_stopped_generation "$name" \
           || ! fm_herdr_lab_require_retired_session "$name" \
           || ! fm_herdr_lab_check_tripwire "$name"; then
          fm_herdr_lab_error "existing state for absent session '$name' is not an authoritatively retired generation"
          fm_herdr_lab_abort_prelaunch "$name" "$owner"
          return 1
        fi
        mode=restart
      else
        fm_herdr_lab_prepare_state "$name" 1 || {
          fm_herdr_lab_abort_prelaunch "$name" "$owner"
          return 1
        }
        mode=new
      fi
      ;;
    1)
    tripwire=$(fm_herdr_lab_tripwire_path "$name")
    [ -f "$tripwire" ] && [ ! -L "$tripwire" ] || {
      fm_herdr_lab_error "missing fleet-state tripwire for existing session '$name'; refusing to adopt it"
      fm_herdr_lab_abort_prelaunch "$name" "$owner"
      return 1
    }
    fm_herdr_lab_require_owned_session "$name" any || {
      fm_herdr_lab_abort_prelaunch "$name" "$owner"
      return 1
    }
    running=$FM_HERDR_LAB_SESSION_RUNNING
    [ "$running" = false ] || {
      fm_herdr_lab_error "session '$name' is not stopped; refusing to re-provision it"
      fm_herdr_lab_abort_prelaunch "$name" "$owner"
      return 1
    }
    fm_herdr_lab_check_tripwire "$name" || {
      fm_herdr_lab_abort_prelaunch "$name" "$owner"
      return 1
    }
    fm_herdr_lab_owned_raw "$name" false session delete "$name" --json >/dev/null 2>&1 || {
      fm_herdr_lab_error "stopped generation for '$name' changed before guarded re-provision"
      fm_herdr_lab_abort_prelaunch "$name" "$owner"
      return 1
    }
    fm_herdr_lab_retire_stopped_generation "$name" || {
      fm_herdr_lab_abort_prelaunch "$name" "$owner"
      return 1
    }
    mode=restart
      ;;
    *)
      fm_herdr_lab_error "session '$name' is ambiguous; refusing to provision it"
      fm_herdr_lab_abort_prelaunch "$name" "$owner"
      return 1
      ;;
  esac

  case "$mode" in
    new) fm_herdr_lab_require_session_absent "$name" || {
      fm_herdr_lab_abort_prelaunch "$name" "$owner"
      return 1
    } ;;
    restart) fm_herdr_lab_require_retired_session "$name" || {
      fm_herdr_lab_abort_prelaunch "$name" "$owner"
      return 1
    } ;;
  esac
  FM_HERDR_LAB_SESSION_OWNER="$owner" \
    herdr server --session "$name" >/dev/null 2>&1 &
  server_pid=$!
  attempt=0
  server_start=
  while [ "$attempt" -lt 20 ]; do
    server_start=$(fm_herdr_lab_process_start "$server_pid" 2>/dev/null || true)
    if [ -n "$server_start" ] \
       && fm_herdr_lab_process_has_session_owner "$server_pid" "$owner"; then
      break
    fi
    kill -0 "$server_pid" 2>/dev/null || break
    server_start=
    sleep 0.01
    attempt=$((attempt + 1))
  done
  if [ -z "$server_start" ] \
     || ! fm_herdr_lab_process_has_session_owner "$server_pid" "$owner"; then
    fm_herdr_lab_cancel_provision "$server_pid"
    fm_herdr_lab_error "helper-owned server launch for '$name' could not be identified"
    return 1
  fi
  fm_herdr_lab_write_session_claim "$name" "$server_pid" "$server_start" "$owner" || {
    fm_herdr_lab_cancel_provision "$server_pid"
    return 1
  }
  attempt=0
  max_attempts=300
  timeout_seconds=60
  while [ "$attempt" -lt "$max_attempts" ]; do
    generation=$(fm_herdr_lab_running_generation "$name" 2>/dev/null || true)
    if [ -n "$generation" ]; then
      if ! fm_herdr_lab_session_process_is_owned "$server_pid" "$server_start" "$owner"; then
        fm_herdr_lab_cancel_provision "$server_pid"
        fm_herdr_lab_error "session '$name' appeared without the helper-owned server launch"
        return 1
      fi
      if fm_herdr_lab_write_session_identity "$name" "$generation" "$server_pid" "$server_start" "$owner"; then
        fm_herdr_lab_require_owned_session "$name" true || {
          fm_herdr_lab_cancel_provision "$server_pid"
          return 1
        }
        if [ "$mode" = restart ]; then
          stop_receipt=$(fm_herdr_lab_stop_receipt_path "$name")
          rm -f "$stop_receipt" || {
            fm_herdr_lab_cancel_provision "$server_pid"
            fm_herdr_lab_error "could not retire the prior stop generation for '$name'"
            return 1
          }
        fi
        fm_herdr_lab_check_tripwire "$name" || {
          fm_herdr_lab_cancel_provision "$server_pid"
          fm_herdr_lab_error "default fleet-state changed during provisioning '$name'"
          return 1
        }
        rm -f "$claim" || return 1
        return 0
      fi
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done
  fm_herdr_lab_cancel_provision "$server_pid"
  fm_herdr_lab_clear_safe_claim "$name" || true
  fm_herdr_lab_error "lab session '$name' did not report running within $timeout_seconds seconds"
  return 1
}

fm_herdr_lab_provision() { # <session>
  local name=${1:-} status
  fm_herdr_lab_lock_session "$name" || return 1
  fm_herdr_lab_provision_locked "$@"
  status=$?
  fm_herdr_lab_unlock_session "$name" || status=1
  return "$status"
}

fm_herdr_lab_prepare() { # <session>
  fm_herdr_lab_provision "$1"
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
  local name=$1 tripwire identity claim stop_receipt
  fm_herdr_lab_check_tripwire "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  identity=$(fm_herdr_lab_identity_path "$name")
  claim=$(fm_herdr_lab_claim_path "$name")
  stop_receipt=$(fm_herdr_lab_stop_receipt_path "$name")
  [ ! -e "$claim" ] && [ ! -L "$claim" ] || {
    fm_herdr_lab_error "session creation claim for '$name' remains; retaining teardown evidence"
    return 1
  }
  if [ -e "$identity" ] || [ -L "$identity" ] \
     || [ -e "$stop_receipt" ] || [ -L "$stop_receipt" ]; then
    [ -f "$identity" ] && [ ! -L "$identity" ] \
      && [ -f "$stop_receipt" ] && [ ! -L "$stop_receipt" ] || {
        fm_herdr_lab_error "named session retirement evidence for '$name' is absent or ambiguous"
        return 1
      }
    fm_herdr_lab_require_retired_session "$name" || {
      fm_herdr_lab_error "named session retirement evidence for '$name' is absent or mismatched"
      return 1
    }
  fi
  rm -f "$identity" "$stop_receipt" || return 1
  rm -f "$tripwire"
}

fm_herdr_lab_require_clean_absent_teardown() { # <session>
  local name=$1 sessions named_count evidence
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot verify clean absence for '$name'"
    return 1
  }
  named_count=$(printf '%s' "$sessions" | jq -er --arg name "$name" '[.sessions[]? | select(.name == $name)] | length' 2>/dev/null) || {
    fm_herdr_lab_error "cannot determine whether lab session '$name' is absent"
    return 1
  }
  [ "$named_count" -eq 0 ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing destructive calls"
    return 1
  }
  for evidence in \
    "$(fm_herdr_lab_tripwire_path "$name")" \
    "$(fm_herdr_lab_identity_path "$name")" \
    "$(fm_herdr_lab_claim_path "$name")" \
    "$(fm_herdr_lab_stop_receipt_path "$name")" \
    "$(fm_herdr_lab_bootstrap_dir "$name")" \
    "$(fm_herdr_lab_bootstrap_dir "$name").retiring.state"; do
    [ ! -e "$evidence" ] && [ ! -L "$evidence" ] || {
      fm_herdr_lab_error "cleanup evidence for '$name' remains; refusing ambiguous teardown"
      return 1
    }
  done
}

fm_herdr_lab_process_start() { # <pid>
  LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

fm_herdr_lab_process_state() { # <pid>
  ps -o state= -p "$1" 2>/dev/null | sed 's/[[:space:]]//g'
}

fm_herdr_lab_process_has_env() { # <pid> <variable> <value>
  local pid=$1 variable=$2 value=$3 token args proc_environ
  [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || return 1
  token="$variable=$value"
  args=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
  case "$args" in
    *"$token"*) return 1 ;;
  esac
  proc_environ="/proc/$pid/environ"
  if [ -r "$proc_environ" ]; then
    tr '\0' '\n' < "$proc_environ" | grep -Fx -- "$token" >/dev/null
    return $?
  fi
  ps eww -p "$pid" -o command= 2>/dev/null | awk -v token="$token" '
    { for (i = 1; i <= NF; i++) if ($i == token) found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

fm_herdr_lab_process_has_owner() { # <pid> <owner-token>
  fm_herdr_lab_process_has_env "$1" FM_HERDR_LAB_BOOTSTRAP_OWNER "$2"
}

fm_herdr_lab_process_has_session_owner() { # <pid> <owner-token>
  fm_herdr_lab_process_has_env "$1" FM_HERDR_LAB_SESSION_OWNER "$2"
}

fm_herdr_lab_session_process_is_owned() { # <pid> <start> <owner-token>
  local current
  current=$(fm_herdr_lab_process_start "$1" 2>/dev/null) || return 1
  [ "$current" = "$2" ] && fm_herdr_lab_process_has_session_owner "$1" "$3"
}

fm_herdr_lab_single_child_pid() { # <pid>
  local pid=$1 raw
  local -a children
  raw=$(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ' || true)
  read -r -a children <<< "$raw"
  [ "${#children[@]}" -eq 1 ] || return 1
  [[ "${children[0]}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${children[0]}"
}

fm_herdr_lab_write_bootstrap_record() { # <session> <client-pid> <client-start> <attach-pid> <attach-start> <owner> [pane]
  local name=$1 client_pid=$2 client_start=$3 attach_pid=$4 attach_start=$5 owner=$6 pane=${7:-} record tmp
  [ -n "$client_pid" ] || client_pid=0
  [ -n "$client_start" ] || client_start=pending
  [ -n "$attach_pid" ] || attach_pid=0
  [ -n "$attach_start" ] || attach_start=pending
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
  if [ -n "$extra" ] \
     || [ "$FM_HERDR_LAB_BOOTSTRAP_SESSION" != "$name" ] \
     || ! [[ "$FM_HERDR_LAB_BOOTSTRAP_PID" =~ ^[0-9]+$ ]] \
     || ! [[ "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_PID" =~ ^[0-9]+$ ]] \
     || ! [[ "$FM_HERDR_LAB_BOOTSTRAP_OWNER" =~ ^fm-herdr-lab:${name}:[0-9]+:[0-9]+:[0-9]+$ ]]; then
    fm_herdr_lab_error "bootstrap client state for '$name' is malformed or mismatched"
    return 1
  fi
  if [ -n "$FM_HERDR_LAB_BOOTSTRAP_PANE" ] \
     && ! [[ "$FM_HERDR_LAB_BOOTSTRAP_PANE" =~ ^[a-zA-Z0-9_:\-]+$ ]]; then
    fm_herdr_lab_error "bootstrap client state for '$name' is malformed or mismatched"
    return 1
  fi
  FM_HERDR_LAB_BOOTSTRAP_PENDING=0
  if [ "$FM_HERDR_LAB_BOOTSTRAP_PID" -eq 0 ] \
     && [ "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_PID" -eq 0 ] \
     && [ "$FM_HERDR_LAB_BOOTSTRAP_START" = pending ] \
     && [ "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_START" = pending ]; then
    FM_HERDR_LAB_BOOTSTRAP_PENDING=1
  elif [ "$FM_HERDR_LAB_BOOTSTRAP_PID" -gt 1 ] \
       && [ "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_PID" -eq 0 ] \
       && [ -n "$FM_HERDR_LAB_BOOTSTRAP_START" ] \
       && [ "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_START" = pending ]; then
    FM_HERDR_LAB_BOOTSTRAP_PENDING=1
  elif [ "$FM_HERDR_LAB_BOOTSTRAP_PID" -gt 1 ] \
       && [ "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_PID" -gt 1 ] \
       && [ "$FM_HERDR_LAB_BOOTSTRAP_PID" != "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_PID" ] \
       && [ -n "$FM_HERDR_LAB_BOOTSTRAP_START" ] \
       && [ -n "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_START" ]; then
    :
  else
    fm_herdr_lab_error "bootstrap client state for '$name' has an invalid lifecycle"
    return 1
  fi
}

fm_herdr_lab_process_is_owned() { # <pid> <start> <owner>
  local current
  current=$(fm_herdr_lab_process_start "$1" 2>/dev/null) || return 1
  [ "$current" = "$2" ] && fm_herdr_lab_process_has_owner "$1" "$3"
}

fm_herdr_lab_require_bootstrap_processes() { # uses FM_HERDR_LAB_BOOTSTRAP_*
  [ "${FM_HERDR_LAB_BOOTSTRAP_PENDING:-0}" -eq 0 ] || {
    fm_herdr_lab_error "bootstrap client state is still pending pane mutation"
    return 1
  }
  if ! fm_herdr_lab_process_is_owned \
    "$FM_HERDR_LAB_BOOTSTRAP_PID" "$FM_HERDR_LAB_BOOTSTRAP_START" "$FM_HERDR_LAB_BOOTSTRAP_OWNER" \
    || ! fm_herdr_lab_process_is_owned \
      "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_PID" "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_START" "$FM_HERDR_LAB_BOOTSTRAP_OWNER"; then
    fm_herdr_lab_error "bootstrap client process ownership is stale or mismatched"
    return 1
  fi
}

fm_herdr_lab_stop_recorded_process() { # <pid> <start> <owner> <label>
  local pid=$1 start=$2 owner=$3 label=$4 attempt=0 current
  kill -0 "$pid" 2>/dev/null || return 0
  fm_herdr_lab_process_is_owned "$pid" "$start" "$owner" || {
    fm_herdr_lab_error "$label PID $pid has stale or mismatched ownership"
    return 1
  }
  kill -TERM "$pid" 2>/dev/null || {
    kill -0 "$pid" 2>/dev/null || return 0
    fm_herdr_lab_error "could not stop $label PID $pid"
    return 1
  }
  while [ "$attempt" -lt 50 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    case "$(fm_herdr_lab_process_state "$pid" 2>/dev/null)" in
      Z*) return 0 ;;
    esac
    current=$(fm_herdr_lab_process_start "$pid" 2>/dev/null) || {
      kill -0 "$pid" 2>/dev/null || return 0
      fm_herdr_lab_error "could not inspect $label PID $pid while stopping"
      return 1
    }
    [ -n "$current" ] || {
      kill -0 "$pid" 2>/dev/null || return 0
      fm_herdr_lab_error "$label PID $pid changed identity while stopping"
      return 1
    }
    [ "$current" = "$start" ] || {
      fm_herdr_lab_error "$label PID $pid changed identity while stopping"
      return 1
    }
    sleep 0.1
    attempt=$((attempt + 1))
  done
  fm_herdr_lab_error "$label PID $pid did not stop after TERM"
  return 1
}

fm_herdr_lab_stop_owned_processes() { # <client-pid> <client-start> <attach-pid> <attach-start> <owner>
  local client_pid=$1 client_start=$2 attach_pid=$3 attach_start=$4 owner=$5 status=0
  if [[ "$attach_pid" =~ ^[0-9]+$ ]] && [ "$attach_pid" -gt 1 ]; then
    fm_herdr_lab_stop_recorded_process "$attach_pid" "$attach_start" "$owner" "bootstrap PTY child" || status=$?
  fi
  if [[ "$client_pid" =~ ^[0-9]+$ ]] && [ "$client_pid" -gt 1 ]; then
    if fm_herdr_lab_stop_recorded_process "$client_pid" "$client_start" "$owner" "bootstrap client"; then
      wait "$client_pid" 2>/dev/null || true
    else
      status=$?
    fi
  fi
  return "$status"
}

fm_herdr_lab_require_no_bootstrap_panes() { # <session>
  local name=$1 panes pane_count
  panes=$(fm_herdr_lab_cli "$name" pane list 2>/dev/null) || return 1
  pane_count=$(printf '%s' "$panes" | jq -es '
    if length != 1 then error("expected one pane-list document") else .[0] end
    | .result.panes
    | if type == "array" then length else error("pane inventory is not an array") end
  ' 2>/dev/null) || {
    fm_herdr_lab_error "bootstrap pane inventory is unreadable during pending cleanup"
    return 1
  }
  [ "$pane_count" -eq 0 ] || {
    fm_herdr_lab_error "bootstrap pane identity is unresolved in '$name'; retaining cleanup evidence"
    return 1
  }
}

fm_herdr_lab_bootstrap_dir_entries_safe() { # <dir> <record> <log>
  local dir=$1 record=$2 log=$3 entry
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  if [ -e "$log" ] || [ -L "$log" ]; then
    [ -f "$log" ] && [ ! -L "$log" ] || return 1
  fi
  (
    shopt -s nullglob dotglob
    for entry in "$dir"/*; do
      case "$entry" in
        "$record"|"$log") ;;
        *) exit 1 ;;
      esac
    done
  )
}

fm_herdr_lab_recover_bootstrap_retirement() { # <session>
  local name=$1 dir record retired
  dir=$(fm_herdr_lab_bootstrap_dir "$name")
  record=$(fm_herdr_lab_bootstrap_record_path "$name")
  retired="$dir.retiring.state"
  [ ! -e "$retired" ] && [ ! -L "$retired" ] && return 0
  [ ! -e "$dir" ] && [ ! -L "$dir" ] || {
    fm_herdr_lab_error "bootstrap client retirement evidence for '$name' is ambiguous"
    return 1
  }
  mkdir "$dir" || return 1
  chmod 700 "$dir" || { rmdir "$dir" 2>/dev/null || true; return 1; }
  mv "$retired" "$record" || {
    rmdir "$dir" 2>/dev/null || true
    return 1
  }
}

fm_herdr_lab_remove_bootstrap_record() { # <session>
  local name=$1 dir record log retired
  fm_herdr_lab_recover_bootstrap_retirement "$name" || return 1
  dir=$(fm_herdr_lab_bootstrap_dir "$name")
  record=$(fm_herdr_lab_bootstrap_record_path "$name")
  log=$(fm_herdr_lab_bootstrap_log_path "$name")
  retired="$dir.retiring.state"
  fm_herdr_lab_bootstrap_dir_entries_safe "$dir" "$record" "$log" || {
    fm_herdr_lab_error "bootstrap client state directory for '$name' contains unexpected state"
    return 1
  }
  [ ! -e "$retired" ] && [ ! -L "$retired" ] || {
    fm_herdr_lab_error "bootstrap client retirement evidence for '$name' is ambiguous"
    return 1
  }
  mv "$record" "$retired" || return 1
  if ! rm -f "$log"; then
    mv "$retired" "$record" 2>/dev/null || true
    return 1
  fi
  if rmdir "$dir" 2>/dev/null; then
    rm -f "$retired" || {
      fm_herdr_lab_error "bootstrap client retirement evidence for '$name' could not be removed"
      return 1
    }
    return 0
  fi
  if [ ! -e "$record" ] && [ ! -L "$record" ]; then
    mv "$retired" "$record" 2>/dev/null || {
      fm_herdr_lab_error "bootstrap client retirement for '$name' failed with retained evidence outside its state directory"
      return 1
    }
  fi
  fm_herdr_lab_error "bootstrap client state directory for '$name' could not be retired"
  return 1
}

fm_herdr_lab_close_bootstrap_pane() { # <session> <pane>
  local name=$1 expected=$2 panes pane_count pane after_count lookup attempt=0 pane_absent=0
  fm_herdr_lab_check_tripwire "$name" || return 1
  fm_herdr_lab_require_owned_session "$name" any || return 1
  panes=$(fm_herdr_lab_cli "$name" pane list 2>/dev/null) || {
    fm_herdr_lab_error "cannot inspect the bootstrap pane before cleanup"
    return 1
  }
  pane_count=$(printf '%s' "$panes" | jq -er '
    select((.result.panes | type) == "array") | (.result.panes | length)
  ' 2>/dev/null) || {
    fm_herdr_lab_error "bootstrap pane inventory is unreadable during cleanup"
    return 1
  }
  case "$pane_count" in
    0) return 0 ;;
    1) ;;
    *)
      fm_herdr_lab_error "bootstrap cleanup found an ambiguous $pane_count-pane inventory in '$name'"
      return 1
      ;;
  esac
  pane=$(printf '%s' "$panes" | jq -er '.result.panes[0].pane_id | select(type == "string" and length > 0)' 2>/dev/null) || {
    fm_herdr_lab_error "bootstrap cleanup found an unidentified pane in '$name'"
    return 1
  }
  if [ "$pane" != "$expected" ]; then
    lookup=$(fm_herdr_lab_owned_raw "$name" true pane get "$expected" 2>&1 || true)
    if printf '%s' "$lookup" | jq -es --arg pane "$expected" '
      length == 1
      and .[0].error.code == "pane_not_found"
      and (.[0].error.message | contains($pane))
    ' >/dev/null 2>&1; then
      fm_herdr_lab_check_tripwire "$name" || return 1
      fm_herdr_lab_require_owned_session "$name" true
      return $?
    fi
    fm_herdr_lab_error "bootstrap cleanup refused a pane identity mismatch in '$name'"
    return 1
  fi
  fm_herdr_lab_owned_raw "$name" true pane close "$expected" >/dev/null 2>&1 || {
    fm_herdr_lab_error "could not close the owned bootstrap pane in '$name'"
    return 1
  }
  while [ "$attempt" -lt 50 ]; do
    after_count=$(fm_herdr_lab_cli "$name" pane list 2>/dev/null | jq -er '
      select((.result.panes | type) == "array") | (.result.panes | length)
    ' 2>/dev/null) || {
      fm_herdr_lab_error "could not confirm bootstrap pane cleanup in '$name'"
      return 1
    }
    if [ "$after_count" -eq 0 ]; then
      pane_absent=1
      break
    fi
    lookup=$(fm_herdr_lab_owned_raw "$name" true pane get "$expected" 2>&1 || true)
    if printf '%s' "$lookup" | jq -es --arg pane "$expected" '
      length == 1
      and .[0].error.code == "pane_not_found"
      and (.[0].error.message | contains($pane))
    ' >/dev/null 2>&1; then
      pane_absent=1
      break
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  [ "$pane_absent" -eq 1 ] || {
    fm_herdr_lab_error "bootstrap pane '$expected' remains after cleanup"
    return 1
  }
  fm_herdr_lab_check_tripwire "$name" || return 1
  fm_herdr_lab_require_owned_session "$name" true
}

fm_herdr_lab_stop_bootstrap_client() { # <session>
  local name=$1 close_pane=${2:-0} dir pane pending snapshot running retain_until_delete=0
  fm_herdr_lab_recover_bootstrap_retirement "$name" || return 1
  dir=$(fm_herdr_lab_bootstrap_dir "$name")
  [ ! -e "$dir" ] && [ ! -L "$dir" ] && return 0
  fm_herdr_lab_read_bootstrap_record "$name" || return 1
  pane=$FM_HERDR_LAB_BOOTSTRAP_PANE
  pending=$FM_HERDR_LAB_BOOTSTRAP_PENDING
  snapshot=$(fm_herdr_lab_session_snapshot "$name") || return 1
  running=$(printf '%s' "$snapshot" | jq -r '.running' 2>/dev/null) || return 1
  case "$running" in
    true)
      if [ "$pending" = 1 ]; then
        fm_herdr_lab_require_owned_session "$name" true || return 1
        if [ -z "$pane" ]; then
          fm_herdr_lab_require_no_bootstrap_panes "$name" || return 1
        else
          fm_herdr_lab_close_bootstrap_pane "$name" "$pane" || return 1
        fi
      elif [ "$close_pane" = 1 ] && [ -n "$pane" ]; then
        fm_herdr_lab_close_bootstrap_pane "$name" "$pane" || return 1
      fi
      ;;
    false)
      fm_herdr_lab_read_session_identity "$name" || return 1
      fm_herdr_lab_read_stop_receipt "$name" || return 1
      fm_herdr_lab_stop_receipt_matches_identity "$name" || return 1
      retain_until_delete=1
      ;;
    *) fm_herdr_lab_error "bootstrap cleanup found an ambiguous session state for '$name'"; return 1 ;;
  esac
  fm_herdr_lab_stop_owned_processes \
    "$FM_HERDR_LAB_BOOTSTRAP_PID" \
    "$FM_HERDR_LAB_BOOTSTRAP_START" \
    "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_PID" \
    "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_START" \
    "$FM_HERDR_LAB_BOOTSTRAP_OWNER" || return 1
  if [ "$retain_until_delete" -eq 1 ]; then
    return 0
  fi
  fm_herdr_lab_remove_bootstrap_record "$name"
}

fm_herdr_lab_retire_bootstrap_after_delete() { # <session>
  local name=$1 dir sessions named_count
  fm_herdr_lab_recover_bootstrap_retirement "$name" || return 1
  dir=$(fm_herdr_lab_bootstrap_dir "$name")
  [ ! -e "$dir" ] && [ ! -L "$dir" ] && return 0
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || return 1
  named_count=$(printf '%s' "$sessions" | jq -er --arg name "$name" \
    '[.sessions[]? | select(.name == $name)] | length' 2>/dev/null) || return 1
  [ "$named_count" -eq 0 ] || {
    fm_herdr_lab_error "cannot retire bootstrap evidence while session '$name' remains"
    return 1
  }
  fm_herdr_lab_read_bootstrap_record "$name" || return 1
  fm_herdr_lab_stop_owned_processes \
    "$FM_HERDR_LAB_BOOTSTRAP_PID" \
    "$FM_HERDR_LAB_BOOTSTRAP_START" \
    "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_PID" \
    "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_START" \
    "$FM_HERDR_LAB_BOOTSTRAP_OWNER" || return 1
  fm_herdr_lab_remove_bootstrap_record "$name"
}

fm_herdr_lab_cleanup_bootstrap_attempt() { # <session> <pane> <client-pid> <client-start> <attach-pid> <attach-start> <owner>
  local name=$1 pane=$2 client_pid=$3 client_start=$4 attach_pid=$5 attach_start=$6 owner=$7 status=0
  if fm_herdr_lab_read_bootstrap_record "$name" >/dev/null 2>&1; then
    [ -n "$pane" ] || pane=$FM_HERDR_LAB_BOOTSTRAP_PANE
  else
    status=1
  fi
  fm_herdr_lab_stop_owned_processes \
    "$client_pid" "$client_start" "$attach_pid" "$attach_start" "$owner" || status=$?
  if [ "$status" -eq 0 ] && [ -z "$pane" ]; then
    fm_herdr_lab_require_owned_session "$name" any || status=$?
    if [ "$status" -eq 0 ]; then
      fm_herdr_lab_require_no_bootstrap_panes "$name" || status=$?
    fi
  fi
  if [ "$status" -eq 0 ] && [ -n "$pane" ]; then
    fm_herdr_lab_close_bootstrap_pane "$name" "$pane" || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    fm_herdr_lab_remove_bootstrap_record "$name" || status=$?
  else
    fm_herdr_lab_error "bootstrap rollback for '$name' did not complete"
  fi
  return "$status"
}

fm_herdr_lab_require_owned_running() { # <session>
  local name=$1 tripwire
  fm_herdr_lab_validate_name "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] && [ ! -L "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; provision it before bootstrap-pane"
    return 1
  }
  fm_herdr_lab_check_tripwire "$name" || return 1
  fm_herdr_lab_require_owned_session "$name" true || {
    fm_herdr_lab_error "bootstrap-pane requires exactly one owned running non-default session named '$name'"
    return 1
  }
}

fm_herdr_lab_bootstrap_pane_locked() { # <session>
  local name=$1 dir log panes pane_count pane listed_pane client_pid client_start attach_pid attach_start owner command attempt platform cwd create_out generation pane_ready=0
  local max_attempts=${FM_HERDR_LAB_BOOTSTRAP_MAX_ATTEMPTS:-100}
  fm_herdr_lab_require_owned_running "$name" || return 1
  command -v script >/dev/null 2>&1 || { fm_herdr_lab_error "script is required for bootstrap-pane"; return 1; }
  command -v stty >/dev/null 2>&1 || { fm_herdr_lab_error "stty is required for bootstrap-pane"; return 1; }
  command -v ps >/dev/null 2>&1 || { fm_herdr_lab_error "ps is required for bootstrap-pane"; return 1; }
  command -v pgrep >/dev/null 2>&1 || { fm_herdr_lab_error "pgrep is required for bootstrap-pane"; return 1; }
  platform=$(uname -s 2>/dev/null) || { fm_herdr_lab_error "cannot determine bootstrap-pane platform"; return 1; }
  case "$platform" in
    Linux) command -v setsid >/dev/null 2>&1 || { fm_herdr_lab_error "setsid is required for Linux bootstrap-pane"; return 1; } ;;
    Darwin) ;;
    *) fm_herdr_lab_error "bootstrap-pane is unsupported on '$platform'"; return 1 ;;
  esac
  [[ "$max_attempts" =~ ^[0-9]+$ ]] && [ "$max_attempts" -ge 1 ] && [ "$max_attempts" -le 100 ] || {
    fm_herdr_lab_error "invalid bootstrap-pane wait bound"
    return 1
  }

  fm_herdr_lab_recover_bootstrap_retirement "$name" || return 1
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
  fm_herdr_lab_write_bootstrap_record "$name" "" "" "" "" "$owner" "" || {
    rmdir "$dir"
    fm_herdr_lab_error "cannot journal the bootstrap pane mutation for '$name'"
    return 1
  }
  cwd=$(pwd -P) || {
    fm_herdr_lab_remove_bootstrap_record "$name" || true
    fm_herdr_lab_error "cannot determine the bootstrap pane working directory"
    return 1
  }
  fm_herdr_lab_require_owned_running "$name" || {
    fm_herdr_lab_error "named session ownership changed before bootstrap pane creation"
    return 1
  }
  create_out=$(fm_herdr_lab_owned_raw "$name" true workspace create --cwd "$cwd" --label "fm-herdr-lab-bootstrap" --no-focus 2>/dev/null) || {
    fm_herdr_lab_cleanup_bootstrap_attempt \
      "$name" "" "" "" "" "" "$owner" \
      || fm_herdr_lab_error "could not roll back the bootstrap pane after workspace creation failure"
    fm_herdr_lab_error "could not create the authoritative bootstrap pane in '$name'"
    return 1
  }
  pane=$(printf '%s' "$create_out" | jq -er '
    .result.root_pane.pane_id
    | select(type == "string" and length > 0)
  ' 2>/dev/null) || {
    fm_herdr_lab_cleanup_bootstrap_attempt \
      "$name" "" "" "" "" "" "$owner" \
      || fm_herdr_lab_error "could not roll back the bootstrap pane after malformed workspace output"
    fm_herdr_lab_error "bootstrap pane creation returned no authoritative pane identity"
    return 1
  }
  [[ "$pane" =~ ^[a-zA-Z0-9_:\-]+$ ]] || {
    fm_herdr_lab_cleanup_bootstrap_attempt \
      "$name" "" "" "" "" "" "$owner" \
      || fm_herdr_lab_error "could not roll back the bootstrap pane after malformed pane identity"
    fm_herdr_lab_error "bootstrap pane creation returned a malformed pane identity"
    return 1
  }
  fm_herdr_lab_write_bootstrap_record "$name" "" "" "" "" "$owner" "$pane" || {
    fm_herdr_lab_cleanup_bootstrap_attempt \
      "$name" "$pane" "" "" "" "" "$owner" \
      || fm_herdr_lab_error "could not roll back the bootstrap pane after journaling its identity"
    return 1
  }
  fm_herdr_lab_require_owned_session "$name" true || {
    fm_herdr_lab_cleanup_bootstrap_attempt \
      "$name" "$pane" "" "" "" "" "$owner" \
      || fm_herdr_lab_error "could not retain or roll back the bootstrap pane after ownership changed"
    fm_herdr_lab_error "named session ownership changed before bootstrap client attachment; retaining bootstrap evidence"
    return 1
  }
  generation=$FM_HERDR_LAB_IDENTITY_GENERATION
  command="unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SESSION HERDR_SOCKET_PATH; stty rows 24 cols 80; exec herdr --expected-generation '$generation' --session '$name'"
  if [ "$platform" = Darwin ]; then
    FM_HERDR_LAB_BOOTSTRAP_OWNER="$owner" \
      TERM=xterm-256color \
      script -q "$log" /bin/sh -c "$command" </dev/null >/dev/null 2>&1 &
  else
    FM_HERDR_LAB_BOOTSTRAP_OWNER="$owner" \
      TERM=xterm-256color \
      setsid script -q -e -c "$command" "$log" </dev/null >/dev/null 2>&1 &
  fi
  client_pid=$!
  client_start=pending
  fm_herdr_lab_write_bootstrap_record \
    "$name" "$client_pid" "$client_start" "" "" "$owner" "$pane" || {
      client_start=$(fm_herdr_lab_process_start "$client_pid" 2>/dev/null || true)
      fm_herdr_lab_cleanup_bootstrap_attempt \
        "$name" "$pane" "$client_pid" "$client_start" "" "" "$owner" \
        || fm_herdr_lab_error "could not retain or roll back the bootstrap client after launch journaling failed"
      return 1
    }

  attempt=0
  client_start=
  while [ "$attempt" -lt 20 ]; do
    client_start=$(fm_herdr_lab_process_start "$client_pid" 2>/dev/null || true)
    [ -n "$client_start" ] && break
    kill -0 "$client_pid" 2>/dev/null || break
    sleep 0.01
    attempt=$((attempt + 1))
  done
  if [ -n "$client_start" ]; then
    fm_herdr_lab_write_bootstrap_record \
      "$name" "$client_pid" "$client_start" "" "" "$owner" "$pane" || {
        fm_herdr_lab_cleanup_bootstrap_attempt \
          "$name" "$pane" "$client_pid" "$client_start" "" "" "$owner" \
          || fm_herdr_lab_error "could not retain or roll back the bootstrap client after identity journaling failed"
        return 1
      }
  fi
  if [ -z "$client_start" ] \
     || ! fm_herdr_lab_process_has_owner "$client_pid" "$owner"; then
    fm_herdr_lab_cleanup_bootstrap_attempt \
      "$name" "$pane" "$client_pid" "$client_start" "" "" "$owner" \
      || fm_herdr_lab_error "could not roll back the bootstrap pane after client startup failure"
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
    fm_herdr_lab_cleanup_bootstrap_attempt \
      "$name" "$pane" "$client_pid" "$client_start" "$attach_pid" "$attach_start" "$owner" \
      || fm_herdr_lab_error "could not roll back the bootstrap pane after PTY startup failure"
    fm_herdr_lab_error "bootstrap client for '$name' did not expose one verifiable PTY child"
    return 1
  fi
  fm_herdr_lab_write_bootstrap_record \
    "$name" "$client_pid" "$client_start" "$attach_pid" "$attach_start" "$owner" "$pane" || {
      fm_herdr_lab_cleanup_bootstrap_attempt \
        "$name" "$pane" "$client_pid" "$client_start" "$attach_pid" "$attach_start" "$owner" \
        || fm_herdr_lab_error "could not roll back the bootstrap pane after state write failure"
      return 1
    }
  fm_herdr_lab_read_bootstrap_record "$name" || {
    fm_herdr_lab_cleanup_bootstrap_attempt \
      "$name" "$pane" "$client_pid" "$client_start" "$attach_pid" "$attach_start" "$owner" \
      || fm_herdr_lab_error "could not clean bootstrap pane after a state-read failure"
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
        listed_pane=$(printf '%s' "$panes" | jq -er '
          .result.panes[0].pane_id | select(type == "string" and length > 0)
        ' 2>/dev/null || true)
        if [ "$listed_pane" = "$pane" ]; then
          pane_ready=1
          break
        fi
        fm_herdr_lab_error "bootstrap-pane returned a pane identity mismatch in '$name'"
        break
        ;;
      *)
        fm_herdr_lab_error "bootstrap-pane created an ambiguous $pane_count-pane inventory in '$name'"
        break
        ;;
    esac
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if [ "$pane_ready" -ne 1 ]; then
    fm_herdr_lab_stop_bootstrap_client "$name" 1 \
      || fm_herdr_lab_error "could not clean bootstrap client after pane wait failure"
    fm_herdr_lab_error "lab session '$name' did not produce exactly one bootstrap pane within 10 seconds"
    return 1
  fi
  fm_herdr_lab_check_tripwire "$name" || return 1
  fm_herdr_lab_require_owned_session "$name" true || return 1
  jq -nc --arg session "$name" --arg pane_id "$pane" --argjson client_pid "$client_pid" \
    '{session:$session,pane_id:$pane_id,client_pid:$client_pid}'
}

fm_herdr_lab_bootstrap_pane() { # <session>
  local name=$1 status
  fm_herdr_lab_lock_session "$name" || return 1
  fm_herdr_lab_bootstrap_pane_locked "$@"
  status=$?
  fm_herdr_lab_unlock_session "$name" || status=1
  return "$status"
}

fm_herdr_lab_stop_locked() { # <session>
  local name=$1 tripwire snapshot running receipt
  fm_herdr_lab_validate_name "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] && [ ! -L "$tripwire" ] || {
    fm_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing stop"
    return 1
  }
  fm_herdr_lab_check_tripwire "$name" || return 1
  receipt=$(fm_herdr_lab_stop_receipt_path "$name")
  if [ ! -e "$receipt" ] && [ ! -L "$receipt" ]; then
    fm_herdr_lab_read_session_identity "$name" || return 1
    [ "$FM_HERDR_LAB_IDENTITY_STATE" = running ] || {
      fm_herdr_lab_error "stopped named session '$name' has no durable stop receipt"
      return 1
    }
    snapshot=$(fm_herdr_lab_session_snapshot "$name") || return 1
    running=$(printf '%s' "$snapshot" | jq -r '.running' 2>/dev/null) || return 1
    case "$running" in
      true) fm_herdr_lab_require_owned_session "$name" true || return 1 ;;
      false) : ;;
      *) fm_herdr_lab_error "refusing stop for '$name': running state is ambiguous"; return 1 ;;
    esac
    fm_herdr_lab_check_tripwire "$name" || return 1
    fm_herdr_lab_begin_stop_receipt "$name" || return 1
  fi
  fm_herdr_lab_stop_bootstrap_client "$name" 1 || return 1
  if [ -e "$receipt" ] || [ -L "$receipt" ]; then
    fm_herdr_lab_read_session_identity "$name" || return 1
    case "$FM_HERDR_LAB_IDENTITY_STATE" in
      running) fm_herdr_lab_resume_stop_receipt "$name" || return 1 ;;
      stopped) fm_herdr_lab_require_owned_session "$name" false || return 1 ;;
      *) fm_herdr_lab_error "named session identity for '$name' has an ambiguous lifecycle"; return 1 ;;
    esac
  else
    fm_herdr_lab_error "stop receipt for '$name' disappeared during cleanup"
    return 1
  fi
  fm_herdr_lab_check_tripwire "$name"
}

fm_herdr_lab_stop() { # <session>
  local name=$1 status
  fm_herdr_lab_lock_session "$name" || return 1
  fm_herdr_lab_stop_locked "$@"
  status=$?
  fm_herdr_lab_unlock_session "$name" || status=1
  return "$status"
}

fm_herdr_lab_teardown_locked() { # <session>
  local name=$1 tripwire sessions delete_status=0 named_count identity
  fm_herdr_lab_validate_name "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] && [ ! -L "$tripwire" ] || {
    fm_herdr_lab_require_clean_absent_teardown "$name"
    return $?
  }
  fm_herdr_lab_check_tripwire "$name" || return 1
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before teardown"
    return 1
  }
  named_count=$(printf '%s' "$sessions" | jq -er --arg name "$name" '[.sessions[]? | select(.name == $name)] | length' 2>/dev/null) || {
    fm_herdr_lab_error "cannot determine whether lab session '$name' exists"
    return 1
  }
  case "$named_count" in
    0)
      identity=$(fm_herdr_lab_identity_path "$name")
      if [ -e "$identity" ] || [ -L "$identity" ]; then
        fm_herdr_lab_retire_stopped_generation "$name" || {
          fm_herdr_lab_error "lab session '$name' disappeared before teardown; retaining ownership evidence"
          return 1
        }
        fm_herdr_lab_require_retired_session "$name" || {
          fm_herdr_lab_error "lab session '$name' disappeared before teardown; retaining ownership evidence"
          return 1
        }
        fm_herdr_lab_retire_bootstrap_after_delete "$name" || return 1
      elif [ -e "$(fm_herdr_lab_bootstrap_dir "$name")" ] \
           || [ -L "$(fm_herdr_lab_bootstrap_dir "$name")" ]; then
        fm_herdr_lab_error "bootstrap evidence remains without a retired session generation for '$name'"
        return 1
      fi
      fm_herdr_lab_verify_tripwire "$name"
      return
      ;;
    1) ;;
    *)
      fm_herdr_lab_error "lab session '$name' is ambiguous before teardown"
      return 1
      ;;
  esac
  fm_herdr_lab_stop_locked "$name" >/dev/null || return 1
  sleep 0.5
  fm_herdr_lab_check_tripwire "$name" || return 1
  fm_herdr_lab_owned_raw "$name" false session delete "$name" --json >/dev/null 2>&1 || delete_status=$?
  sessions=$(fm_herdr_lab_session_list "$name" 2>/dev/null) || {
    fm_herdr_lab_error "cannot confirm removal of lab session '$name' after teardown"
    return 1
  }
  named_count=$(printf '%s' "$sessions" | jq -er --arg name "$name" '[.sessions[]? | select(.name == $name)] | length' 2>/dev/null) || {
    fm_herdr_lab_error "cannot determine whether lab session '$name' remains after teardown"
    return 1
  }
  if [ "$named_count" -ne 0 ]; then
    if [ "$delete_status" -ne 0 ]; then
      fm_herdr_lab_error "session delete failed for '$name' and the lab session remains"
    else
      fm_herdr_lab_error "lab session '$name' remains after teardown"
    fi
    return 1
  fi
  fm_herdr_lab_retire_stopped_generation "$name" || return 1
  fm_herdr_lab_retire_bootstrap_after_delete "$name" || return 1
  fm_herdr_lab_verify_tripwire "$name"
}

fm_herdr_lab_teardown() { # <session>
  local name=$1 status
  fm_herdr_lab_lock_session "$name" || return 1
  fm_herdr_lab_teardown_locked "$@"
  status=$?
  fm_herdr_lab_unlock_session "$name" || status=1
  return "$status"
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
      fm_herdr_lab_run "$@"
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
