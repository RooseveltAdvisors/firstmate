#!/usr/bin/env bash
# Live drive: real fm-crew-state.sh + fm-watch.sh against a disposable lab home and lab tmux server.
set -u
ROOT=$PWD
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/fakebin"
export TMUX_TMPDIR="$LAB/tmux"; unset TMUX
FB=$LAB/fakebin
ln -s "$(command -v sleep)" "$FB/grok"
# fake no-mistakes: status served from a file so the scenario can flip it
sed -n '/^  cat > "\$fb\/no-mistakes" <<'"'"'SH'"'"'$/,/^SH$/p' tests/fm-crew-state.test.sh | sed '1d;$d' > "$FB/no-mistakes"
sed -i 's|"${FM_FAKE_AXI_STATUS:-}"|"$(cat "$FM_LIVE_AXI_FILE")"|g; s|"${FM_FAKE_AXI_HOME:-${FM_FAKE_AXI_STATUS:-}}"|"$(cat "$FM_LIVE_AXI_FILE")"|' "$FB/no-mistakes"
chmod +x "$FB/no-mistakes"
WT=$LAB/wt; git init -q -b fm/ci-live "$WT"; git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
tmux -L fm-lab new-session -d -s lab -n fm-ci "bash -c 'printf \"waiting at the gate\\n\"; exec $FB/grok 100000'"
SOCK=$(tmux -L fm-lab display -p '#{socket_path}')
export TMUX="$SOCK,0,0"
S=$LAB/state
printf 'window=lab:fm-ci\nworktree=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$WT" > "$S/live.meta"
printf 'working: implementation committed\n' > "$S/live.status"
export FM_LIVE_AXI_FILE=$LAB/axi
ci_status() { cat <<E
run:
  id: "01RUN"
  branch: fm/ci-live
  status: running
  head: "abc1234"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
E
}
review_status() { cat <<E
run:
  id: "01RUN"
  branch: fm/ci-live
  status: running
  head: "abc1234"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
E
}
run_env() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" PATH="$FB:$PATH" FM_STALE_ESCALATE_SECS=4 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 "$@"; }
ack() { local err=$LAB/drain.err seq gen
  run_env bin/fm-wake-drain.sh > "$LAB/drain.out" 2> "$err"; cat "$LAB/drain.out" >> "$LAB/wakes.log"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && run_env bin/fm-wake-drain.sh --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1; }
drive() {  # <label> <seconds>
  local label=$1 secs=$2 end pid
  echo "### phase: $label" | tee -a "$LAB/wakes.log"
  end=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$end" ]; do
    run_env bin/fm-watch.sh >> "$LAB/watch-$label.out" 2>>"$LAB/watch-$label.err" & pid=$!
    while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$end" ]; do sleep 1; done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    ack
  done
  echo "--- watcher stdout ($label):"; cat "$LAB/watch-$label.out"
}
echo "== fm-crew-state.sh, ci step running:"
ci_status > "$LAB/axi"; run_env bin/fm-crew-state.sh live
echo "== fm-crew-state.sh, review step running:"
review_status > "$LAB/axi"; run_env bin/fm-crew-state.sh live
echo "== endpoint verdict:"; ( . bin/fm-backend.sh 2>/dev/null; run_env bash -c '. bin/fm-backend.sh; fm_backend_agent_state tmux lab:fm-ci' )
touch "$S/.afk"
hk() {  # <label>
  run_env FM_TEST_DAEMON_SOURCED=1 FM_STALE_ESCALATE_SECS=240 bash -c '. bin/fm-supervise-daemon.sh; housekeeping "$FM_HOME/state"' >/dev/null 2>&1
  echo "--- after housekeeping ($1): escalations buffer:"; cat "$S/.subsuper-escalations" 2>/dev/null || echo "(empty)"
  echo "    stale marker age: $(( $(date +%s) - $(cat "$S/.subsuper-stale-live" 2>/dev/null || date +%s) ))s; paused marker: $(cat "$S/.subsuper-paused-live" 2>/dev/null || echo none)"; }
ci_status > "$LAB/axi"
echo $(( $(date +%s) - 300 )) > "$S/.subsuper-stale-live"; hk "ci step, stale 300s"
echo $(( $(date +%s) - 300 )) > "$S/.subsuper-stale-live"; echo $(( $(date +%s) - 20000 )) > "$S/.subsuper-paused-live"; hk "ci step, stale 300s, pause window 20000s old"
rm -f "$S/.subsuper-escalations"* "$S/.subsuper-paused-live"
review_status > "$LAB/axi"
echo $(( $(date +%s) - 300 )) > "$S/.subsuper-stale-live"; hk "review step, stale 300s"
rm -f "$S/.subsuper-escalations"*
ci_status > "$LAB/axi"; tmux -L fm-lab respawn-pane -k -t lab:fm-ci "bash -c 'printf \"waiting\\n\"; exec sleep 100000'"
echo "endpoint now: $(run_env bash -c '. bin/fm-backend.sh; fm_backend_agent_state tmux lab:fm-ci')"
echo $(( $(date +%s) - 300 )) > "$S/.subsuper-stale-live"; hk "ci step, agent gone from pane"
echo $(( $(date +%s) - 300 )) > "$S/.subsuper-stale-live"; hk "ci step, agent gone, second crossing (expect no repeat)"



tmux -L fm-lab kill-server; rm -rf "$LAB"
