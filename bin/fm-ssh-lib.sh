# shellcheck shell=bash
# Strict parent-to-Secondmate SSH transport.
#
# This is automation transport, not a runtime backend and not Herdr remote
# attach. It only runs existing Firstmate commands in an already-provisioned
# remote home. SSH aliases must resolve to an unprivileged account with a
# pre-established known_hosts entry and authentication; this code never copies
# credentials, forwards an agent, or weakens host verification.

if [ -n "${_FM_SSH_LIB_SOURCED:-}" ]; then
  # shellcheck disable=SC2317 # Executable fallback keeps direct invocation inert.
  return 0 2>/dev/null || exit 0
fi
_FM_SSH_LIB_SOURCED=1

FM_SSH_UNREADABLE_RC=74
FM_SSH_UNREACHABLE_RC=75

fm_remote_id_valid() {
  case "${1:-}" in ''|*[!A-Za-z0-9_:-]*) return 1 ;; esac
}

fm_remote_host_valid() {
  case "${1:-}" in ''|.|..|-*|*'@'*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
}

fm_remote_path_valid() {
  case "${1:-}" in /|''|/*[!A-Za-z0-9_./-]*|*'//'*) return 1 ;; esac
  case "/${1#/}/" in */../*) return 1 ;; esac
  case "$1" in /*) return 0 ;; *) return 1 ;; esac
}

fm_secondmate_registry_field() {  # <registry> <id> <home|host|projects>
  local registry=$1 id=$2 key=$3 line value
  fm_remote_id_valid "$id" || return 1
  case "$key" in home|host|projects) ;; *) return 1 ;; esac
  [ -f "$registry" ] && [ ! -L "$registry" ] || return 1
  line=$(grep -E "^- $id( |$)" "$registry" 2>/dev/null | tail -1 || true)
  [ -n "$line" ] || return 1
  value=$(printf '%s\n' "$line" | sed -n "s/.*[;(][[:space:]]*${key}:[[:space:]]*\\([^;)]*\\)[;)].*/\\1/p" \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

fm_secondmate_remote_identity() {  # <meta> <registry> <id>; sets FM_REMOTE_HOST/HOME
  local meta=$1 registry=$2 id=$3 host='' home=''
  FM_REMOTE_HOST=
  FM_REMOTE_HOME=
  fm_remote_id_valid "$id" || return 2
  if [ -f "$meta" ] && [ ! -L "$meta" ]; then
    home=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  fi
  host=$(fm_secondmate_registry_field "$registry" "$id" host 2>/dev/null || true)
  [ -n "$home" ] || home=$(fm_secondmate_registry_field "$registry" "$id" home 2>/dev/null || true)
  [ -n "$host" ] || return 1
  fm_remote_host_valid "$host" && fm_remote_path_valid "$home" || return 2
  # shellcheck disable=SC2034 # Outputs are consumed by sourcing callers.
  FM_REMOTE_HOST=$host
  # shellcheck disable=SC2034 # Outputs are consumed by sourcing callers.
  FM_REMOTE_HOME=$home
}

fm_ssh_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_ssh_run() {  # <host> <command> [arg...]; stdin passes through
  local host=$1 ssh_bin=${FM_SSH_BIN:-ssh} connect=${FM_SSH_CONNECT_TIMEOUT:-8}
  local bound=${FM_SSH_OPERATION_TIMEOUT:-30} command arg err rc
  local -a runner ssh_argv
  shift
  fm_remote_host_valid "$host" || return "$FM_SSH_UNREADABLE_RC"
  [ "$#" -gt 0 ] || return "$FM_SSH_UNREADABLE_RC"
  case "$connect:$bound" in *[!0-9:]*|0:*|*:0) return "$FM_SSH_UNREADABLE_RC" ;; esac
  # shellcheck disable=SC2016 # id expands only in the remote shell.
  command='test "$(id -u)" -ne 0 && exec'
  for arg in "$@"; do
    command="$command $(fm_ssh_quote "$arg")"
  done
  err=$(mktemp "${TMPDIR:-/tmp}/fm-ssh.XXXXXX") || return "$FM_SSH_UNREADABLE_RC"
  if command -v timeout >/dev/null 2>&1; then
    runner=(timeout "$bound")
  elif command -v gtimeout >/dev/null 2>&1; then
    runner=(gtimeout "$bound")
  elif command -v perl >/dev/null 2>&1; then
    # shellcheck disable=SC2016 # Perl owns its own variables.
    runner=(perl -e 'my $t = shift; my $pid = fork; die unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$bound")
  else
    rm -f "$err"
    return "$FM_SSH_UNREADABLE_RC"
  fi
  ssh_argv=("$ssh_bin" -T \
    -o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no \
    -o ForwardAgent=no -o ClearAllForwardings=yes -o PermitLocalCommand=no \
    -o RequestTTY=no -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
    -o NumberOfPasswordPrompts=0 -o ConnectionAttempts=1 -o ConnectTimeout="$connect" \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -o LogLevel=ERROR \
    -- "$host" "$command")
  if "${runner[@]}" "${ssh_argv[@]}" 2>"$err"; then
    rc=0
  else
    rc=$?
  fi
  rm -f "$err"
  case "$rc" in 0) return 0 ;; 124|137|143|255) return "$FM_SSH_UNREACHABLE_RC" ;; *) return "$FM_SSH_UNREADABLE_RC" ;; esac
}
