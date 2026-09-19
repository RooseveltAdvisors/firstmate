#!/usr/bin/env bash
# What the CAPTAIN sees when a ship crewmate reports `done:` with only a local
# commit. Drives the real bin/fm-watch.sh against a real git worktree and reads
# the real durable wake queue firstmate consumes (bin/fm-wake-drain.sh).
# Run once against the base tree and once against the branch tree to compare.
set -u
TREE=$1      # repository tree whose bin/ is under test
WORK=$2      # scratch dir
LABEL=$3

STATE="$WORK/state"
FAKEBIN="$WORK/fakebin"
ID=falsedone
WT="$WORK/wt"
mkdir -p "$STATE" "$FAKEBIN" "$WORK/upstream.git"

# The crewmate's real worktree: one local commit, never pushed.
git init -q --bare "$WORK/upstream.git"
git init -q "$WORK/repo"
git -C "$WORK/repo" -c user.name=demo -c user.email=d@example.invalid commit -q --allow-empty -m base
git -C "$WORK/repo" remote add origin "$WORK/upstream.git"
git -C "$WORK/repo" push -q origin HEAD:refs/heads/main
git -C "$WORK/repo" worktree add -q -b "fm/$ID" "$WT"
printf 'feature\n' > "$WT/feature.txt"
git -C "$WT" add feature.txt
git -C "$WT" -c user.name=crew -c user.email=c@example.invalid commit -q -m "implement the feature"

cat > "$STATE/$ID.meta" <<META
window=test:fm-$ID
kind=ship
mode=no-mistakes
harness=pi
worktree=$WT
META

# Minimal terminal + crew-state fakes so the watcher runs headless.
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = list-windows ] && { printf '%s\n' "${FM_FAKE_TMUX_WINDOWS:-}"; exit 0; }
[ "${1:-}" = capture-pane ] && exit 0
exit 1
SH
cat > "$FAKEBIN/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: unknown · source: pane · harness state unavailable\n'
SH
cat > "$WORK/steer-recorder" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$FM_STEER_LOG"
exit 0
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/fm-crew-state.sh" "$WORK/steer-recorder"

printf '══ %s ══\n' "$LABEL"
printf 'crewmate state/%s.status (what the worker reported):\n  %s\n' \
  "$ID" "$(printf 'done: implementation complete, all tests pass')"
printf 'crewmate branch fm/%s: 1 local commit, no remote-tracking ref, no PR\n\n' "$ID"
printf 'done: implementation complete, all tests pass\n' > "$STATE/$ID.status"

export FM_STEER_LOG="$WORK/steer.log"
: > "$FM_STEER_LOG"
mkdir -p "$WORK/no-git-root"
PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$WORK/no-git-root" \
  FM_GATE_REFUSE_BYPASS=1 FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
  FM_FAKE_TMUX_WINDOWS="fm-$ID" FM_DONE_GUARD_SEND="$WORK/steer-recorder" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$TREE/bin/fm-watch.sh" > "$WORK/watch.out" 2>&1 &
pid=$!
exited=no
for _ in $(seq 1 120); do
  kill -0 "$pid" 2>/dev/null || { exited=yes; break; }
  sleep 0.25
done
[ "$exited" = yes ] || { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }

printf -- '--- watcher stdout ---\n'
cat "$WORK/watch.out"
printf -- '--- watcher woke firstmate (process exited)? %s ---\n' "$exited"
printf -- '--- durable wake queue firstmate drains ---\n'
FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$WORK/no-git-root" FM_GATE_REFUSE_BYPASS=1 \
  PATH="$FAKEBIN:$PATH" "$TREE/bin/fm-wake-drain.sh" 2>&1 \
  | sed -n '1,12p'
printf -- '--- message delivered to the crewmate ---\n'
if [ -s "$FM_STEER_LOG" ]; then cat "$FM_STEER_LOG"; else printf '(none)\n'; fi
