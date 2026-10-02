#!/usr/bin/env bash
# Live scenario driver: Herdr server-birth color scrub (PR NO_COLOR/herdr server scrub).
#
# Uses bin/fm-herdr-lab.sh's prepare/tripwire/teardown contract for two named
# fm-lab-* sessions:
#   - fixed session:  the PRODUCT adapter (fm_backend_herdr_server_ensure from
#                     bin/backends/herdr.sh) births the real herdr server under a
#                     color-polluted launcher environment (the agent-launch case).
#   - control session: a direct `herdr server` birth under the same pollution -
#                     byte-identical to the base commit's launch minus the scrub -
#                     to prove the inheritance the fix exists to prevent.
# The observable is the environment of (a) the real herdr server process and
# (b) a real crew pane created afterwards in each session.
set -u

ROOT="/home/jon/.no-mistakes/worktrees/2f32188048b1/01M3XCMC6EC0Q9PGX9F3PP45XN"
EV="/home/jon/.no-mistakes/evidence/01M3XCMC6EC0Q9PGX9F3PP45XN"

command -v herdr >/dev/null || { echo "no herdr"; exit 1; }
command -v jq >/dev/null || { echo "no jq"; exit 1; }

# Drop any inherited Herdr pane identity; this shell is not a herdr pane.
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION

# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-lab.sh"     # production owner of lab-session guards

SESSION="fm-lab-colorfix-$$-$RANDOM"
CONTROL="fm-lab-colorctrl-$$-$RANDOM"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab home create failed"; exit 1; }
export FM_HOME="$LAB"

fail=0
torn_down=0
note() { echo "== $* =="; }
cleanup() {
  if [ "$torn_down" != 1 ]; then
    fm_herdr_lab_teardown "$SESSION" >/dev/null 2>&1 || echo "WARN: teardown of $SESSION failed"
    fm_herdr_lab_teardown "$CONTROL" >/dev/null 2>&1 || echo "WARN: teardown of $CONTROL failed"
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

# --- server pid for a named lab session, via its listening socket -----------
server_pid() { # <session>
  ss -xlp 2>/dev/null | grep -F "sessions/$1/herdr.sock" 2>/dev/null \
    | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1
}

read_env() { # <pid> <outfile>
  tr '\0' '\n' < "/proc/$1/environ" > "$2" 2>/dev/null || return 1
}

poll_running() { # <session>
  local i=0
  while [ "$i" -lt 60 ]; do
    if fm_herdr_lab_cli "$1" status --json 2>/dev/null | jq -e '.server.running == true' >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

# --- setup: tripwire both named lab sessions --------------------------------
note "lab prepare (fleet-state tripwire) for $SESSION and $CONTROL"
fm_herdr_lab_prepare "$SESSION" || { echo "FAIL: prepare $SESSION"; exit 1; }
fm_herdr_lab_prepare "$CONTROL" || { echo "FAIL: prepare $CONTROL"; exit 1; }

# --- FIXED: the product adapter births the server under pollution -----------
note "fixed: fm_backend_herdr_server_ensure under NO_COLOR=1 launcher env"
env NO_COLOR=1 FORCE_COLOR=0 CLICOLOR=0 CLICOLOR_FORCE=1 \
  FM_HERDR_SENTINEL=kept FM_HOME="$LAB" \
  bash -c '
    set -u
    . "$1/bin/fm-backend.sh"
    fm_backend_source herdr || exit 2
    fm_backend_herdr_server_ensure "$2"
  ' _ "$ROOT" "$SESSION" || { echo "FAIL: server_ensure did not bring the session up"; fail=1; }
poll_running "$SESSION" || { echo "FAIL: fixed session server not running"; exit 1; }

FIXED_PID=$(server_pid "$SESSION")
echo "fixed server pid: ${FIXED_PID:-<none>}"
[ -n "$FIXED_PID" ] || { echo "FAIL: could not find the fixed session server process"; fail=1; }

# --- CONTROL: base-commit-style birth (direct herdr server, scrub absent) ---
note "control: direct 'herdr server' birth under the same pollution (pre-fix launch shape)"
env NO_COLOR=1 FORCE_COLOR=0 CLICOLOR=0 CLICOLOR_FORCE=1 \
  FM_HERDR_SENTINEL=kept FM_HOME="$LAB" HERDR_SESSION="$CONTROL" \
  herdr server --session "$CONTROL" >/dev/null 2>&1 &
poll_running "$CONTROL" || { echo "FAIL: control session server not running"; exit 1; }

CTRL_PID=$(server_pid "$CONTROL")
echo "control server pid: ${CTRL_PID:-<none>}"
[ -n "$CTRL_PID" ] || { echo "FAIL: could not find the control session server process"; fail=1; }

# --- server birth environment ----------------------------------------------
if [ -n "$FIXED_PID" ]; then
  read_env "$FIXED_PID" "$EV/herdr-fixed-server-env.txt" || { echo "FAIL: cannot read fixed server env"; fail=1; }
fi
if [ -n "$CTRL_PID" ]; then
  read_env "$CTRL_PID" "$EV/herdr-control-server-env.txt" || { echo "FAIL: cannot read control server env"; fail=1; }
fi

check_vars() { # <file> <mode: clean|polluted> <label>
  local f=$1 mode=$2 label=$3 n
  [ -s "$f" ] || { echo "FAIL($label): empty env capture"; fail=1; return; }
  if [ "$mode" = clean ]; then
    for n in NO_COLOR FORCE_COLOR CLICOLOR CLICOLOR_FORCE; do
      if grep -q "^$n=" "$f"; then echo "FAIL($label): $n present in the server birth env"; fail=1; fi
    done
    grep -q '^FM_HOME=' "$f" && { echo "FAIL($label): FM_HOME leaked into server birth env"; fail=1; }
  else
    grep -q '^NO_COLOR=1' "$f" || { echo "FAIL($label): control did not inherit NO_COLOR (inheritance unproven)"; fail=1; }
  fi
  grep -q '^FM_HERDR_SENTINEL=kept' "$f" || { echo "FAIL($label): unrelated sentinel lost"; fail=1; }
  grep -E '^(NO_COLOR|FORCE_COLOR|CLICOLOR|CLICOLOR_FORCE|FM_HERDR_SENTINEL|FM_HOME)=' "$f" | sort | sed "s/^/$label: /"
}
check_vars "$EV/herdr-fixed-server-env.txt" clean "fixed-server"
check_vars "$EV/herdr-control-server-env.txt" polluted "control-server"

# --- crew panes created AFTER the birth -------------------------------------
probe_pane() { # <session> <label> <clean|polluted> -> reads/writes $EV/herdr-<label>-pane-env.txt
  local s=$1 label=$2 mode=$3 out="$EV/herdr-$2-pane-env.txt" ws tab pane pid raw body info
  raw=$(env NO_COLOR=1 FORCE_COLOR=0 CLICOLOR=0 CLICOLOR_FORCE=1 \
    FM_HERDR_SENTINEL=kept FM_HOME="$LAB" bash -c '
      set -u
      . "$1/bin/fm-backend.sh"
      fm_backend_source herdr || exit 2
      fm_backend_herdr_container_ensure "$3/projects" launcher-home "$2"
    ' _ "$ROOT" "$s" "$LAB") || { echo "FAIL($label): container_ensure failed"; fail=1; return 1; }
  body=${raw#*:}; ws=${body%%$'\t'*}; tab=${body#*$'\t'}
  echo "$label: container_ensure -> session=$s ws=$ws tab=$tab"
  pane=$(fm_herdr_lab_cli "$s" pane list --workspace "$ws" 2>/dev/null \
    | jq -r '[.. | .pane_id? | select(type == "string")] | first // empty')
  [ -n "$pane" ] || { echo "FAIL($label): no pane in the workspace"; fail=1; return 1; }
  info=$(fm_herdr_lab_cli "$s" pane process-info --pane "$pane" 2>/dev/null)
  printf '%s\n' "$info" > "$EV/herdr-${label}-pane-process.json"
  pid=$(printf '%s' "$info" | jq -r '[.. | .pid? | select(type == "number")] | first // empty')
  [ -n "$pid" ] || { echo "FAIL($label): no pid in pane process-info"; fail=1; return 1; }
  tr '\0' '\n' < "/proc/$pid/environ" > "$out" 2>/dev/null || { echo "FAIL($label): cannot read pane env"; fail=1; return 1; }
  echo "$label: pane=$pane pid=$pid"
  if [ "$mode" = clean ]; then
    if grep -q '^NO_COLOR=' "$out"; then echo "FAIL($label): pane env carries NO_COLOR (launcher color control reached a crew pane)"; fail=1; fi
  else
    grep -q '^NO_COLOR=1' "$out" || { echo "FAIL($label): control pane did NOT inherit NO_COLOR - inheritance unproven here"; fail=1; }
  fi
  grep -E '^(NO_COLOR|FORCE_COLOR|CLICOLOR|CLICOLOR_FORCE|FM_HERDR_SENTINEL)=' "$out" | sort | sed "s/^/$label-pane: /"
}
note "fixed: create a crew pane AFTER the scrubbed birth"
probe_pane "$SESSION" fixed clean
note "control: create a crew pane after the unscrubbed birth (leak expected)"
probe_pane "$CONTROL" ctrl polluted

# --- adversarial reuse: a second polluted server_ensure must change nothing --
note "adversarial: second server_ensure under pollution against the running fixed server"
reuse=$(env NO_COLOR=1 FORCE_COLOR=0 CLICOLOR=0 CLICOLOR_FORCE=1 FM_HERDR_SENTINEL=kept FM_HOME="$LAB" \
  bash -c '
    set -u
    . "$1/bin/fm-backend.sh"
    fm_backend_source herdr || exit 2
    fm_backend_herdr_server_ensure "$2"
  ' _ "$ROOT" "$SESSION") || { echo "FAIL: reuse server_ensure errored"; fail=1; }
echo "reuse server_ensure rc=0 ($reuse)"
NEW_PID=$(server_pid "$SESSION")
[ "$NEW_PID" = "$FIXED_PID" ] || { echo "FAIL: reuse restarted the server ($FIXED_PID -> $NEW_PID)"; fail=1; }
read_env "$NEW_PID" "$EV/herdr-fixed-server-env-after-reuse.txt" || { echo "FAIL: reread env failed"; fail=1; }
if grep -qE '^(NO_COLOR|FORCE_COLOR|CLICOLOR|CLICOLOR_FORCE)=' "$EV/herdr-fixed-server-env-after-reuse.txt"; then
  echo "FAIL: reuse path injected color control into the running server"
  fail=1
fi
grep -E '^(NO_COLOR|FORCE_COLOR|CLICOLOR|CLICOLOR_FORCE|FM_HERDR_SENTINEL)=' \
  "$EV/herdr-fixed-server-env-after-reuse.txt" | sort | sed 's/^/after-reuse: /'

# --- teardown via the lab helper (tripwire verified) ------------------------
note "teardown both lab sessions (fleet-state tripwire checked)"
if fm_herdr_lab_teardown "$SESSION" && fm_herdr_lab_teardown "$CONTROL"; then
  torn_down=1
  echo "teardown ok; default session untouched (tripwire matched)"
else
  echo "FAIL: teardown/tripwire failed"; fail=1
fi
left=$(herdr session list --json | jq -r --arg n "$SESSION" --arg c "$CONTROL" \
  '[.sessions[]? | select(.name == $n or .name == $c)] | length')
[ "$left" = 0 ] || { echo "FAIL: lab sessions remain after teardown"; fail=1; }
trap - EXIT
cleanup

if [ "$fail" -eq 0 ]; then echo "ALL HERDR BIRTH-ENV CHECKS PASSED"; else echo "HERDR BIRTH-ENV CHECKS FAILED"; fi
exit "$fail"
