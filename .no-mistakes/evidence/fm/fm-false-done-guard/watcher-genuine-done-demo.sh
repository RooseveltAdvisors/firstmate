#!/usr/bin/env bash
# The other half of the gate: a GENUINE ship done must still reach the captain.
# Same watcher, same queue as watcher-false-done-demo.sh, but the crewmate
# pushed its branch and its done names a PR the forge reports open (read live).
set -u
TREE=$1
WORK=$2
PR_URL=$3
REAL_ORIGIN=https://github.com/kunchenguid/firstmate.git

STATE="$WORK/state"; FAKEBIN="$WORK/fakebin"; ID=realdone; WT="$WORK/wt"
mkdir -p "$STATE" "$FAKEBIN" "$WORK/upstream.git" "$WORK/nogit"
git init -q --bare "$WORK/upstream.git"
git init -q "$WORK/repo"
git -C "$WORK/repo" -c user.name=demo -c user.email=d@example.invalid commit -q --allow-empty -m base
git -C "$WORK/repo" remote add origin "$WORK/upstream.git"
git -C "$WORK/repo" push -q origin HEAD:refs/heads/main
git -C "$WORK/repo" worktree add -q -b "fm/$ID" "$WT"
printf 'feature\n' > "$WT/feature.txt"
git -C "$WT" add feature.txt
git -C "$WT" -c user.name=crew -c user.email=c@example.invalid commit -q -m "implement the feature"
git -C "$WT" push -q -u origin "fm/$ID"
git -C "$WT" remote set-url origin "$REAL_ORIGIN"

printf 'window=test:fm-%s\nkind=ship\nmode=no-mistakes\nharness=pi\nworktree=%s\n' "$ID" "$WT" > "$STATE/$ID.meta"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = list-windows ] && { printf '%s\n' "${FM_FAKE_TMUX_WINDOWS:-}"; exit 0; }
[ "${1:-}" = capture-pane ] && exit 0
exit 1
SH
cat > "$FAKEBIN/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: unknown - source: pane - harness state unavailable\n'
SH
cat > "$WORK/steer-recorder" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$FM_STEER_LOG"
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/fm-crew-state.sh" "$WORK/steer-recorder"

printf 'crewmate branch fm/%s: pushed to its remote\n' "$ID"
printf 'crewmate state/%s.status: done: PR %s checks green\n\n' "$ID" "$PR_URL"
printf 'done: PR %s checks green\n' "$PR_URL" > "$STATE/$ID.status"

export FM_STEER_LOG="$WORK/steer.log"; : > "$FM_STEER_LOG"
PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$WORK/nogit" \
  FM_GATE_REFUSE_BYPASS=1 FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
  FM_FAKE_TMUX_WINDOWS="fm-$ID" FM_DONE_GUARD_SEND="$WORK/steer-recorder" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$TREE/bin/fm-watch.sh" > "$WORK/watch.out" 2>&1 &
pid=$!
for _ in $(seq 1 80); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

printf -- '--- watcher stdout ---\n'; cat "$WORK/watch.out"
printf -- '--- durable wake queue firstmate drains ---\n'
FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$WORK/nogit" FM_GATE_REFUSE_BYPASS=1 \
  PATH="$FAKEBIN:$PATH" "$TREE/bin/fm-wake-drain.sh" 2>&1 | sed -n '1,8p'
printf -- '--- message delivered to the crewmate ---\n'
if [ -s "$FM_STEER_LOG" ]; then cat "$FM_STEER_LOG"; else printf '(none - nothing to correct)\n'; fi
