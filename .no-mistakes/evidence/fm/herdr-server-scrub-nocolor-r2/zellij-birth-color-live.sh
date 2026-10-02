#!/usr/bin/env bash
# Live scenario driver: zellij session-birth color scrub (PR NO_COLOR/herdr server scrub).
#
# zellij is not installed on this machine, so the real 0.44.0 release binary
# (the version docs/zellij-backend.md verifies against) was unpacked into the
# run's disposable workspace (.testtmp/zellij) - the shipped unit test
# (tests/fm-backend-zellij.test.sh) only runs against a canned fake, so this
# driver measures what the REAL zellij server and a REAL crew pane inherit.
#
# Isolation: HOME/XDG_*/TMPDIR per run root, so the server socket lives under
# <root>/run/zellij/... and nothing reaches real zellij state. Roots are short
# unix paths because sockaddr_un.sun_path caps at 108 bytes (a long worktree
# TMPDIR makes the zellij server panic - verified incidentally).
# Safety: sessions are named fm-lab-*, teardown uses only zellij_safe_delete
# from tests/zellij-test-safety.sh (never kill-all-sessions).
set -u

ROOT="/home/jon/.no-mistakes/worktrees/2f32188048b1/01M3XCMC6EC0Q9PGX9F3PP45XN"
EV="/home/jon/.no-mistakes/evidence/01M3XCMC6EC0Q9PGX9F3PP45XN"
ZBIN_DIR="$ROOT/.testtmp/zellij"
[ -x "$ZBIN_DIR/zellij" ] || { echo "FAIL: disposable zellij binary missing"; exit 1; }
command -v jq >/dev/null || { echo "no jq"; exit 1; }

# shellcheck source=/dev/null
. "$ROOT/tests/zellij-test-safety.sh"   # zellij_safe_delete / zellij_refuse_if_unsafe

FIXED_SESSION="fm-lab-zcolor-fixed"
CTRL_SESSION="fm-lab-zcolor-ctrl"
FIX="/tmp/zf$$"     # short: socket path = $XDG_RUNTIME_DIR/zellij/contract_version_1/<session>
CTRL="/tmp/zc$$"
POLLUTE="NO_COLOR=1 FORCE_COLOR=0 CLICOLOR=0 CLICOLOR_FORCE=1 FM_ZELLIJ_SENTINEL=kept"

fail=0
note() { echo "== $* =="; }

setup_root() {
  mkdir -p "$1/home" "$1/run" "$1/config" "$1/data" "$1/cache" "$1/tmp" || exit 1
  chmod 700 "$1/run"
}
iso() { # <root> -> VAR=val word list for env(1) (paths contain no spaces)
  printf 'HOME=%s/home XDG_RUNTIME_DIR=%s/run XDG_CONFIG_HOME=%s/config XDG_DATA_HOME=%s/data XDG_CACHE_HOME=%s/cache TMPDIR=%s/tmp' \
    "$1" "$1" "$1" "$1" "$1" "$1"
}

server_pid() { # <root> <session>
  pgrep -f "zellij --server .*$1/run/zellij/.*/$2\$" 2>/dev/null | head -1
}

pane_pid() { # <server pid> -> first PTY child (the crew pane's shell)
  pgrep -P "$1" 2>/dev/null | head -1
}

read_env() { # <pid> <outfile>
  tr '\0' '\n' < "/proc/$1/environ" > "$2" 2>/dev/null
}

iso_exec() { # <root> <cmd...> - run a command with that root's isolation env exported
  local r=$1; shift
  ( export HOME="$r/home" XDG_RUNTIME_DIR="$r/run" XDG_CONFIG_HOME="$r/config" \
      XDG_DATA_HOME="$r/data" XDG_CACHE_HOME="$r/cache" TMPDIR="$r/tmp" \
      PATH="$ZBIN_DIR:$PATH"; "$@" )
}

cleanup() {
  for pair in "$FIX:$FIXED_SESSION" "$CTRL:$CTRL_SESSION"; do
    r=${pair%%:*}; s=${pair#*:}
    if [ -d "$r" ]; then
      iso_exec "$r" zellij_safe_delete "$s" 2>/dev/null || true
    fi
    p=$(server_pid "$r" "$s")
    [ -z "$p" ] || kill "$p" 2>/dev/null || true
  done
  rm -rf "$FIX" "$CTRL"
}
trap cleanup EXIT

note "precondition: no zellij server is running on this machine"
if pgrep -x zellij >/dev/null 2>&1; then
  echo "NOTE: a zellij process existed beforehand:"; pgrep -a -x zellij
else
  echo "no pre-existing zellij process - every zellij pid below is created by this driver"
fi
setup_root "$FIX"; setup_root "$CTRL"

# --- FIXED: the product adapter births the session under pollution ----------
note "fixed: fm_backend_zellij_server_ensure under NO_COLOR=1 launcher env"
env $(iso "$FIX") PATH="$ZBIN_DIR:$PATH" $POLLUTE bash -c '
  set -u
  . "$1/bin/fm-backend.sh"
  fm_backend_source zellij || exit 2
  fm_backend_zellij_server_ensure "$2"
' _ "$ROOT" "$FIXED_SESSION" || { echo "FAIL: server_ensure did not bring the session up"; fail=1; }

i=0; FIXPID=
while [ "$i" -lt 40 ]; do
  FIXPID=$(server_pid "$FIX" "$FIXED_SESSION")
  [ -n "$FIXPID" ] && break
  sleep 0.25; i=$((i + 1))
done
echo "fixed server pid: ${FIXPID:-<none>}"
[ -n "$FIXPID" ] || { echo "FAIL: no zellij server process for the fixed session"; fail=1; }

# --- CONTROL: base-commit-style birth (direct attach, scrub absent) ---------
note "control: direct 'zellij attach -b' birth under the same pollution (pre-fix launch shape)"
# shellcheck disable=SC2086
env $(iso "$CTRL") PATH="$ZBIN_DIR:$PATH" $POLLUTE zellij attach -b "$CTRL_SESSION" </dev/null >/dev/null 2>&1 &
i=0; CTRLPID=
while [ "$i" -lt 40 ]; do
  CTRLPID=$(server_pid "$CTRL" "$CTRL_SESSION")
  [ -n "$CTRLPID" ] && break
  sleep 0.25; i=$((i + 1))
done
echo "control server pid: ${CTRLPID:-<none>}"
[ -n "$CTRLPID" ] || { echo "FAIL: no zellij server process for the control session"; fail=1; }

# --- server + crew-pane birth environment ----------------------------------
if [ -n "$FIXPID" ]; then
  read_env "$FIXPID" "$EV/zellij-fixed-server-env.txt" || { echo "FAIL: cannot read fixed server env"; fail=1; }
  FP=$(pane_pid "$FIXPID"); echo "fixed pane pid: ${FP:-<none>}"
  [ -n "$FP" ] && read_env "$FP" "$EV/zellij-fixed-pane-env.txt" || { echo "FAIL: fixed session has no pane process"; fail=1; }
fi
if [ -n "$CTRLPID" ]; then
  read_env "$CTRLPID" "$EV/zellij-control-server-env.txt" || { echo "FAIL: cannot read control server env"; fail=1; }
  CP=$(pane_pid "$CTRLPID"); echo "control pane pid: ${CP:-<none>}"
  [ -n "$CP" ] && read_env "$CP" "$EV/zellij-control-pane-env.txt" || { echo "FAIL: control session has no pane process"; fail=1; }
fi

check_vars() { # <file> <clean|polluted> <label>
  local f=$1 mode=$2 label=$3 n
  [ -s "$f" ] || { echo "FAIL($label): empty env capture"; fail=1; return; }
  if [ "$mode" = clean ]; then
    for n in NO_COLOR FORCE_COLOR CLICOLOR CLICOLOR_FORCE; do
      if grep -q "^$n=" "$f"; then echo "FAIL($label): $n present"; fail=1; fi
    done
  else
    grep -q '^NO_COLOR=1' "$f" || { echo "FAIL($label): control did not inherit NO_COLOR - inheritance unproven"; fail=1; }
  fi
  grep -q '^FM_ZELLIJ_SENTINEL=kept' "$f" || { echo "FAIL($label): unrelated sentinel lost"; fail=1; }
  grep -E '^(NO_COLOR|FORCE_COLOR|CLICOLOR|CLICOLOR_FORCE|FM_ZELLIJ_SENTINEL)=' "$f" | sort | sed "s/^/$label: /"
}
check_vars "$EV/zellij-fixed-server-env.txt" clean "fixed-server"
check_vars "$EV/zellij-fixed-pane-env.txt" clean "fixed-pane"
check_vars "$EV/zellij-control-server-env.txt" polluted "control-server"
check_vars "$EV/zellij-control-pane-env.txt" polluted "control-pane"

# --- adversarial reuse: a second polluted server_ensure must change nothing --
if [ -n "$FIXPID" ]; then
  note "adversarial: second server_ensure under pollution against the running session"
  env $(iso "$FIX") PATH="$ZBIN_DIR:$PATH" $POLLUTE bash -c '
    set -u
    . "$1/bin/fm-backend.sh"
    fm_backend_source zellij || exit 2
    fm_backend_zellij_server_ensure "$2"
  ' _ "$ROOT" "$FIXED_SESSION" || { echo "FAIL: reuse server_ensure errored"; fail=1; }
  NEWPID=$(server_pid "$FIX" "$FIXED_SESSION")
  [ "$NEWPID" = "$FIXPID" ] || { echo "FAIL: reuse restarted the server ($FIXPID -> $NEWPID)"; fail=1; }
  read_env "$NEWPID" "$EV/zellij-fixed-server-env-after-reuse.txt" || { echo "FAIL: reread failed"; fail=1; }
  if grep -qE '^(NO_COLOR|FORCE_COLOR|CLICOLOR|CLICOLOR_FORCE)=' "$EV/zellij-fixed-server-env-after-reuse.txt"; then
    echo "FAIL: reuse injected color control into the running server"; fail=1
  fi
  grep -E '^(NO_COLOR|FORCE_COLOR|CLICOLOR|CLICOLOR_FORCE|FM_ZELLIJ_SENTINEL)=' \
    "$EV/zellij-fixed-server-env-after-reuse.txt" | sort | sed 's/^/after-reuse: /'
fi

# --- teardown: only zellij_safe_delete, then verify our servers are gone ----
note "teardown (zellij_safe_delete, explicit named sessions only)"
for pair in "$FIX:$FIXED_SESSION" "$CTRL:$CTRL_SESSION"; do
  r=${pair%%:*}; s=${pair#*:}
  if iso_exec "$r" zellij_safe_delete "$s"; then
    echo "deleted session $s"
  else
    echo "FAIL: zellij_safe_delete refused/failed for $s"; fail=1
  fi
done
sleep 1
left=$(pgrep -f "zellij --server .*/zellij/.*/fm-lab-zcolor-" 2>/dev/null | wc -l)
[ "$left" = 0 ] || { echo "FAIL: $left zellij server(s) still running after teardown"; pgrep -af "zellij --server" ; fail=1; }
trap - EXIT
cleanup

if [ "$fail" -eq 0 ]; then echo "ALL ZELLIJ BIRTH-ENV CHECKS PASSED"; else echo "ZELLIJ BIRTH-ENV CHECKS FAILED"; fi
exit "$fail"
