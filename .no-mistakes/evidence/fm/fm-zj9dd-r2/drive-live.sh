#!/usr/bin/env bash
# Live driver for fm-zj9dd (wedge detector must not escalate a lane parked at
# no-mistakes' ci step).
#
# Drives the REAL product end to end in an isolated environment:
#   - a disposable lab FM_HOME (bin/fm-lab-home.sh create) on its own tmux
#     server socket under $LAB/tmux (never the default tmux server),
#   - a real tmux pane running the real `claude` CLI (machine login) as the
#     recorded lane endpoint - real capture-pane reads, real agent liveness,
#   - the REAL bin/fm-crew-state.sh as the watcher's classifier, with only the
#     EXTERNAL `no-mistakes` CLI (a different product) shimmed on PATH,
#   - the REAL bin/fm-watch.sh watcher process polling it.
#
# Scenarios:
#   ci        fixed watcher vs a lane at the ci step: no wedge, CI recheck wording
#   base      base-commit watcher vs the identical fixture: reproduces the
#             reported failure (repeated "possible wedge" escalations)
#   local     fixed watcher vs the same lane on a LOCAL step: wedge ladder intact
#   dead      fixed watcher vs a ci lane whose endpoint has no agent: the
#             once-only gone-endpoint report still wins over the ci defer
#
# Usage: drive-live.sh <ci|base|local|dead> <bin-dir> <rounds>
set -u

REPO=/home/jon/.no-mistakes/worktrees/46339c0817e0/01M3G1J3M8WAN0GKCGY3ETYJA0
EV=/home/jon/.no-mistakes/evidence/01M3G1J3M8WAN0GKCGY3ETYJA0
LAB=$(cat "$EV/lab-path.txt")

BINDIR=$2
ROUNDS=${3:-4}
SCENARIO=$1

export TMUX_TMPDIR="$LAB/tmux"
export SHIM_BIN="$LAB/shimbin"

# --- fixtures: what the external no-mistakes CLI reports ---------------------
axi_ci() {
  cat <<'EOF'
run:
  id: "01RUN"
  branch: fm/zj9dd-live
  status: running
  head: "abc1234"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

axi_local() {
  cat <<'EOF'
run:
  id: "01RUN"
  branch: fm/zj9dd-live
  status: running
  head: "abc1234"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
}

case "$SCENARIO" in
  ci|base|dead|daemon-ci) SHIM_AXI=$(axi_ci); SHIM_CI_LOGS='CI checks running' ;;
  green)                    SHIM_AXI=$(axi_ci); SHIM_CI_LOGS='all CI checks passed - still monitoring until merged or closed' ;;
  local|daemon-local)      SHIM_AXI=$(axi_local); SHIM_CI_LOGS='' ;;
  *) echo "unknown scenario: $SCENARIO" >&2; exit 2 ;;
esac
export SHIM_AXI SHIM_CI_LOGS

# --- lane fixture: recorded window, status log, endpoint ---------------------
reset_lane() { # <endpoint: claude|sleep>
  local ep=$1
  rm -f "$LAB"/state/*.meta "$LAB"/state/*.status "$LAB"/state/.* 2>/dev/null || true
  find "$LAB/state" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  mkdir -p "$LAB/state" "$LAB/config"
  cat > "$LAB/state/ci-lane.meta" <<EOF
window=fm:ci-lane
worktree=$LAB/wt
kind=ship
harness=claude
backend=tmux
EOF
  printf 'working: implementation committed\n' > "$LAB/state/ci-lane.status"
  touch -d '90 seconds ago' "$LAB/state/ci-lane.status"
  # Recreate the recorded endpoint as a shell-pane, then put the requested
  # foreground process in it: a real `claude` child for the live-endpoint
  # scenarios, nothing but the shell for the gone-endpoint scenario.
  if tmux list-windows -t fm -F '#{window_name}' | grep -qx ci-lane; then
    tmux send-keys -t fm:ci-lane C-c 2>/dev/null || true
    sleep 1
    tmux kill-window -t fm:ci-lane 2>/dev/null || true
    sleep 1
  fi
  tmux new-window -t fm -n ci-lane -c "$PWD"
  sleep 1
  if [ "$ep" = claude ]; then
    tmux send-keys -t fm:ci-lane 'claude' Enter
    sleep 8
  fi
}

ack_cycle() { # <state> - acknowledge a surfaced wake the way firstmate's drain does
  local state=$1 err sequence generation
  err="$state/.drive-drain.err"
  FM_HOME="$LAB" PATH="$SHIM_BIN:$PATH" TMUX_TMPDIR="$LAB/tmux" \
    env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE \
        -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    "$REPO/bin/fm-wake-drain.sh" >/dev/null 2>"$err" || true
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\).*/\1/p' "$err")
  rm -f "$err"
  if [ -n "$sequence" ]; then
    FM_HOME="$LAB" PATH="$SHIM_BIN:$PATH" TMUX_TMPDIR="$LAB/tmux" \
      env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE \
          -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      "$REPO/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1 || true
    echo "  (acked wake cycle $sequence)"
  fi
}

run_watch_round() { # <bindir> <out> <round> -> 0 if the watcher surfaced (exited), 1 if it stayed alive
  local bindir=$1 out=$2 n=$3 pid waited=0
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE \
      -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      -u TMUX \
    FM_HOME="$LAB" \
    PATH="$SHIM_BIN:$PATH" \
    TMUX_TMPDIR="$LAB/tmux" \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_STALE_ESCALATE_SECS=8 FM_PAUSE_RESURFACE_SECS=12 \
    SHIM_AXI="$SHIM_AXI" SHIM_CI_LOGS="$SHIM_CI_LOGS" \
    "$bindir/fm-watch.sh" >> "$out" 2>&1 &
  pid=$!
  while [ "$waited" -lt 40 ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; echo "  round $n: watcher surfaced and exited after ~${waited}s"; return 0; }
    sleep 1
    waited=$((waited + 1))
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  echo "  round $n: watcher stayed alive the whole round (absorbed every poll)"
  return 1
}

# --- away-mode daemon scenarios -------------------------------------------
daemon_round() { # <bindir> <expect: ci|wedge>
  local bindir=$1 expect=$2 waited=0 key
  touch "$LAB/state/.afk"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE \
      -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      -u TMUX \
    FM_HOME="$LAB" PATH="$SHIM_BIN:$PATH" TMUX_TMPDIR="$LAB/tmux" \
    FM_SUPERVISOR_TARGET=fm:zsh FM_SUPERVISOR_BACKEND=tmux \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_STALE_ESCALATE_SECS=8 FM_PAUSE_RESURFACE_SECS=12 FM_HOUSEKEEPING_TICK=3 \
    FM_ESCALATE_BATCH_SECS=999999 FM_HEARTBEAT_SCAN_SECS=999999 \
    FM_WEDGE_ALARM_EXEC=discard \
    SHIM_AXI="$SHIM_AXI" SHIM_CI_LOGS="$SHIM_CI_LOGS" \
    "$bindir/fm-supervise-daemon.sh" >> "$EV/$SCENARIO-daemon.out" 2>&1 &
  DPID=$!
  while [ "$waited" -lt 90 ]; do
    sleep 1; waited=$((waited + 1))
    if [ "$expect" = ci ]; then
      if grep -q 'still waiting on CI' "$LAB/state/.subsuper-escalations" 2>/dev/null; then
        echo "  daemon ci recheck digest appeared after ~${waited}s"; break
      fi
      if grep -q 'possible wedge' "$LAB/state/.subsuper-escalations" 2>/dev/null; then
        echo "  daemon WEDGE-ESCALATED a ci lane after ~${waited}s"; break
      fi
    else
      if grep -q 'possible wedge' "$LAB/state/.subsuper-escalations" 2>/dev/null; then
        echo "  daemon wedge escalation appeared after ~${waited}s"; break
      fi
    fi
    if ! kill -0 "$DPID" 2>/dev/null; then echo "  daemon exited early"; break; fi
  done
  kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
  pkill -f "$bindir/fm-watch.sh" 2>/dev/null || true
  rm -f "$LAB/state/.afk"
  echo "  --- state/.subsuper-escalations:"
  sed 's/^/    /' "$LAB/state/.subsuper-escalations" 2>/dev/null || echo "    (absent)"
  echo "  --- stale marker:"
  key=$(printf '%s' 'fm:ci-lane' | tr ':/.' '___')
  if [ -e "$LAB/state/.subsuper-stale-$key" ]; then
    echo "    present (age $(( $(date +%s) - $(cat "$LAB/state/.subsuper-stale-$key") ))s)"
  else
    echo "    absent"
  fi
  echo "  --- daemon log tail:"
  tail -15 "$EV/$SCENARIO-daemon.out" 2>/dev/null | sed 's/^/    /'
}

case "$SCENARIO" in
  daemon-ci|daemon-local)
    echo "=== scenario=$SCENARIO bin=$BINDIR $(date -u +%H:%M:%S) ==="
    reset_lane claude
    echo "--- lane endpoint:"
    tmux list-windows -t fm -F '#{window_name} pane=#{pane_current_command}'
    echo "--- real fm-crew-state.sh verdict:"
    env -u NO_MISTAKES_GATE FM_HOME="$LAB" PATH="$SHIM_BIN:$PATH" \
      SHIM_AXI="$SHIM_AXI" SHIM_CI_LOGS="$SHIM_CI_LOGS" TMUX_TMPDIR="$LAB/tmux" \
      "$REPO/bin/fm-crew-state.sh" ci-lane | sed 's/^/    /'
    : > "$EV/$SCENARIO-daemon.out"
    rm -f "$LAB/state/.subsuper-escalations" "$LAB/state/.subsuper-escalations.since"
    if [ "$SCENARIO" = daemon-ci ]; then
      daemon_round "$BINDIR" ci
    else
      daemon_round "$BINDIR" wedge
    fi
    echo "=== done $(date -u +%H:%M:%S) ==="
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
echo "=== scenario=$SCENARIO bin=$BINDIR rounds=$ROUNDS $(date -u +%H:%M:%S) ==="
echo "--- lane endpoint before fixture:"
tmux list-windows -t fm -F '#{window_name} pane=#{pane_current_command}'

reset_lane "$([ "$SCENARIO" = dead ] && echo sleep || echo claude)"
echo "--- lane endpoint after fixture:"
tmux list-windows -t fm -F '#{window_name} pane=#{pane_current_command}'
echo "--- real fm-crew-state.sh verdict:"
env -u NO_MISTAKES_GATE FM_HOME="$LAB" PATH="$SHIM_BIN:$PATH" \
  SHIM_AXI="$SHIM_AXI" SHIM_CI_LOGS="$SHIM_CI_LOGS" TMUX_TMPDIR="$LAB/tmux" \
  "$REPO/bin/fm-crew-state.sh" ci-lane; echo "    (rc=$?)"
echo "--- agent liveness probe:"
bash -c "set -u; . '$REPO/bin/fm-backend.sh'; echo \"    state=\$(fm_backend_agent_state tmux fm:ci-lane)\""

OUT="$EV/$SCENARIO-watch.out"
: > "$OUT"
n=1
while [ "$n" -le "$ROUNDS" ]; do
  run_watch_round "$BINDIR" "$OUT" "$n"
  rc=$?
  echo "  queue after round $n:"
  awk -F '\t' '{ print "    [" $3 "] " $4 " :: " $5 }' "$LAB/state/.wake-queue" 2>/dev/null | sed 's/^/  /'
  ack_cycle "$LAB/state"
  n=$((n + 1))
  sleep 2
done

echo "--- wake queue (kind/window/reason):"
awk -F '\t' '{ print "    [" $3 "] " $4 " :: " $5 }' "$LAB/state/.wake-queue" 2>/dev/null || echo "    (no wake queue)"
echo "--- wedge escalation counter file:"
key=$(printf '%s' 'fm:ci-lane' | tr ':/.' '___')
if [ -e "$LAB/state/.wedge-escalations-$key" ]; then echo "    count=$(cat "$LAB/state/.wedge-escalations-$key")"; else echo "    (absent - never counted a wedge escalation)"; fi
echo "--- watcher stdout highlights:"
grep -E 'possible wedge|demand-deep-inspection|awaiting the forge checks|agent dead|agent missing|rechecked on a long cadence' "$OUT" | sed 's/^/    /' || echo "    (none)"
echo "=== done $(date -u +%H:%M:%S) ==="
