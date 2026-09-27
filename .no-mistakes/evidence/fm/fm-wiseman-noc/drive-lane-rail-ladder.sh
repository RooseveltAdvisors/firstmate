#!/usr/bin/env bash
# Live scenario driver for branch fm/fm-wiseman-noc (test phase).
#
# Drives the real product end to end in a disposable lab home:
#   - bin/fm-lab-home.sh creates the marked lab home
#   - a real tmux server on the lab's private TMUX_TMPDIR hosts real lane panes
#   - bin/fm-lane-liveness.sh (read/check/selfcheck/routes/arm/disarm)
#   - bin/fm-lane-recover.sh (plan/run)
#   - bin/fm-alert-route.sh and bin/fm-seat-state-advise.sh
# No live response lane, no real fleet home, and no default tmux server is
# touched. Everything is torn down at the end of this script.
set -u

ROOT=/home/jon/.no-mistakes/worktrees/46339c0817e0/01M3G30814BNJEZTBE1P25ZC4J
cd "$ROOT" || exit 1

TOTAL=0
FAILS=0
assert() {  # <description> <command...>  (command must succeed)
  local desc=$1
  shift
  TOTAL=$(( TOTAL + 1 ))
  if "$@" >/dev/null 2>&1; then
    printf 'ASSERT PASS: %s\n' "$desc"
  else
    FAILS=$(( FAILS + 1 ))
    printf 'ASSERT FAIL: %s\n' "$desc"
  fi
}
run() {  # <label> <command...>
  local label=$1
  shift
  printf '\n===== %s\n' "$label"
  printf '$ FM_HOME=<lab> TMUX_TMPDIR=<lab>/tmux'
  printf ' %q' "$@"
  printf '\n'
  env FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" "$@" 2>&1
  printf '(exit %s)\n' "$?"
}

# --- lab home ----------------------------------------------------------------
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
printf 'lab home: %s\n' "$LAB"
bin/fm-lab-home.sh create "$LAB" || exit 1
mkdir -p "$LAB/tmux" || exit 1
export TMUX_TMPDIR="$LAB/tmux"

# --- fixtures ----------------------------------------------------------------
CFG="$LAB/config/response-lanes.conf"
cat > "$CFG" <<'EOF'
# lab fixture: thresholds left at their documented defaults
W=900
D=1800
E=600
M=50
SELF=900
RECOVERY=off
lane stalebeat
lane freshbeat
lane stalled
lane router
EOF

meta() {  # <lane> <home> <window>
  cat > "$LAB/state/$1.meta" <<EOF
window=$3
endpoint_task_id=$1
worktree=$2
project=$2
harness=pi
kind=secondmate
mode=secondmate
yolo=off
home=$2
projects=alpha
EOF
}

NOW=$(date +%s)
for lane in stalebeat freshbeat stalled router; do
  mkdir -p "$LAB/lanes/$lane/state" "$LAB/state/$lane.inbox/handled"
  meta "$lane" "$LAB/lanes/$lane" "sess:$lane"
  : > "$LAB/lanes/$lane/state/.last-watcher-beat"
done
# stalebeat: supervision beat 4000s in the past (over W=900)
TZ=UTC0 touch -t "$(TZ=UTC0 date -d "@$(( NOW - 4000 ))" +%Y%m%d%H%M.%S 2>/dev/null)" \
  "$LAB/lanes/stalebeat/state/.last-watcher-beat"
# stalled: one pending record whose oldest age (4000s) is over D=1800, five handled
printf 'schema=1\nat=now\n--\nwork order\n' > "$LAB/state/stalled.inbox/001.msg"
TZ=UTC0 touch -t "$(TZ=UTC0 date -d "@$(( NOW - 4000 ))" +%Y%m%d%H%M.%S 2>/dev/null)" \
  "$LAB/state/stalled.inbox/001.msg"
for n in 001 002 003 004 005; do
  printf 'schema=1\nat=now\n--\nhandled work %s\n' "$n" > "$LAB/state/stalled.inbox/handled/$n.msg"
done
# router: one handled record, one delivered+correlated record, one delivered-only record
printf 'schema=1\nat=now\n--\nfirst alert\n' > "$LAB/state/router.inbox/handled/001.msg"
printf 'schema=1\nat=now\n--\ncorr=aaaabbbbccccdddd second alert\n' > "$LAB/state/router.inbox/002.msg"
printf 'schema=1\nat=now\n--\ncorr=deadbeefdeadbeef third alert\n' > "$LAB/state/router.inbox/003.msg"
printf 'status at=now corr=aaaabbbbccccdddd handled\n' > "$LAB/state/router.status"

# --- real tmux panes for the lane endpoints ----------------------------------
tmux new-session -d -s sess -n stalebeat 'sleep 100000'
tmux new-window -d -t sess -n freshbeat 'sleep 100000'
tmux new-window -d -t sess -n stalled bash
tmux new-window -d -t sess -n router 'sleep 100000'
sleep 1
printf '\n===== setup: the lab tmux server really hosts the lane windows\n'
tmux list-windows -t sess -F '#{window_name}'
printf -- '--- pane of sess:stalled (readable pane: an interactive shell prompt)\n'
tmux capture-pane -p -t sess:stalled | head -3
printf -- '--- pane of sess:stalled via bin/fm-peek.sh (the rail pane reader)\n'
env FM_HOME="$LAB" bin/fm-peek.sh stalled 60 | head -3

# =========================================================================
# Scenario: rail heartbeat is check-only (read never masks rail silence)
# =========================================================================
printf '\n########## Scenario: heartbeat is written only by check ##########\n'
run 'selfcheck before any sweep' bin/fm-lane-liveness.sh selfcheck
assert 'a configured rail with no completed sweep reports it (selfcheck)' \
  grep -q 'never completed a sweep' <<<"$(env FM_HOME="$LAB" bin/fm-lane-liveness.sh selfcheck)"

run 'read sweep 1' bin/fm-lane-liveness.sh read | tee "$LAB/out-read1.txt"
assert 'a completed read does NOT write the heartbeat' \
  test ! -e "$LAB/state/.lane-liveness-beat"
OUT=$(env FM_HOME="$LAB" bin/fm-lane-liveness.sh selfcheck 2>&1)
assert 'selfcheck still reports no sweep after a completed read (read does not mask silence)' \
  grep -q 'never completed a sweep' <<<"$OUT"

run 'check sweep' bin/fm-lane-liveness.sh check
assert 'a completed check writes the heartbeat' test -e "$LAB/state/.lane-liveness-beat"
OUT=$(env FM_HOME="$LAB" bin/fm-lane-liveness.sh selfcheck 2>&1)
assert 'selfcheck goes silent once check has written the heartbeat' \
  test -z "$OUT"

# Backdate the heartbeat past SELF, then prove a read cannot mask the silence.
TZ=UTC0 touch -t "$(TZ=UTC0 date -d "@$(( $(date +%s) - 960 ))" +%Y%m%d%H%M.%S)" \
  "$LAB/state/.lane-liveness-beat"
BEAT_BEFORE=$(stat -c %Y "$LAB/state/.lane-liveness-beat")
run 'selfcheck with a stale heartbeat' bin/fm-lane-liveness.sh selfcheck
OUT=$(env FM_HOME="$LAB" bin/fm-lane-liveness.sh selfcheck 2>&1)
assert 'a heartbeat older than SELF=900s is reported as rail silence' \
  grep -q 'over SELF=900s' <<<"$OUT"
run 'read with a stale heartbeat' bin/fm-lane-liveness.sh read >/dev/null
BEAT_AFTER=$(stat -c %Y "$LAB/state/.lane-liveness-beat")
assert 'read leaves the stale heartbeat untouched (it is check'"'"'s completion signal)' \
  test "$BEAT_BEFORE" = "$BEAT_AFTER"
OUT=$(env FM_HOME="$LAB" bin/fm-lane-liveness.sh selfcheck 2>&1)
assert 'rail silence is still reported after another completed read (no masking)' \
  grep -q 'over SELF=900s' <<<"$OUT"

# =========================================================================
# Scenario: rail reading - section-2 fields and per-lane verdicts
# =========================================================================
printf '\n########## Scenario: rail read emits the section-2 reading ##########\n'
ROW=$(grep '^lane=stalebeat ' "$LAB/out-read1.txt")
printf 'stalebeat row: %s\n' "$ROW"
assert 'stalebeat (beat 4000s old) reads verdict=dead' \
  grep -q 'lane=stalebeat .*verdict=dead' "$LAB/out-read1.txt"
assert 'the dead verdict names the stale supervision beat and the W threshold' \
  grep -q 'lane=stalebeat .*supervision beat age .* over W=900s' "$LAB/out-read1.txt"
ROW=$(grep '^lane=freshbeat ' "$LAB/out-read1.txt")
printf 'freshbeat row: %s\n' "$ROW"
assert 'freshbeat (fresh beat, drained inbox) reads verdict=alive' \
  grep -q 'lane=freshbeat .*verdict=alive' "$LAB/out-read1.txt"
for field in inbox_drain_age_s pending_count handled_count pending_reply_missed \
             pending_reply_resolved error_signature_class watcher_beat_age_s \
             agent_status route_evidence_count; do
  assert "every lane line carries the section-2 field $field" \
    grep -q "^lane=.*${field}=" "$LAB/out-read1.txt"
done
assert 'stalebeat probe reports the real ambiguous tmux endpoint state' \
  grep -q 'lane=stalebeat .*agent_status=ambiguous' "$LAB/out-read1.txt"
assert 'the sweep 1 journal recorded the pane-read class and handled baseline' \
  grep -q '^stalled none ' "$LAB/state/.lane-liveness-lanes"
printf 'journal after sweep 1: %s\n' "$(cat "$LAB/state/.lane-liveness-lanes")"

# =========================================================================
# Scenario: an unread pane cannot freeze the movement baseline onto alive
# =========================================================================
printf '\n########## Scenario: unread pane cannot let a stalled lane read alive ##########\n'
# The lane handles two more records, then its pane stops being readable.
printf 'schema=1\nat=now\n--\nhandled work 006\n' > "$LAB/state/stalled.inbox/handled/006.msg"
printf 'schema=1\nat=now\n--\nhandled work 007\n' > "$LAB/state/stalled.inbox/handled/007.msg"
tmux send-keys -t sess:stalled 'clear; exec sleep 100000' Enter
sleep 2
printf -- '--- pane of sess:stalled after the transition (blank => error class unknown)\n'
tmux capture-pane -p -t sess:stalled | head -3 | od -c | head -3
touch "$LAB/lanes/freshbeat/state/.last-watcher-beat" \
      "$LAB/lanes/stalled/state/.last-watcher-beat" \
      "$LAB/lanes/router/state/.last-watcher-beat"

run 'read sweep 2 (pane now unreadable, handled moved 5 -> 7)' bin/fm-lane-liveness.sh read | tee "$LAB/out-read2.txt"
assert 'sweep 2 advanced the handled baseline to 7 even though the pane was unread' \
  grep -q '^stalled none [0-9]* 7$' "$LAB/state/.lane-liveness-lanes"
printf 'journal after sweep 2: %s\n' "$(cat "$LAB/state/.lane-liveness-lanes")"
printf 'stalled row (sweep 2): %s\n' "$(grep '^lane=stalled ' "$LAB/out-read2.txt")"

touch "$LAB/lanes/freshbeat/state/.last-watcher-beat" \
      "$LAB/lanes/stalled/state/.last-watcher-beat" \
      "$LAB/lanes/router/state/.last-watcher-beat"
run 'read sweep 3 (pane still unreadable, pending still over D, nothing moved)' bin/fm-lane-liveness.sh read | tee "$LAB/out-read3.txt"
ROW=$(grep '^lane=stalled ' "$LAB/out-read3.txt")
printf 'stalled row (sweep 3): %s\n' "$ROW"
assert 'a stalled lane with an unreadable pane reads verdict=dead, never alive' \
  grep -q 'lane=stalled .*verdict=dead' "$LAB/out-read3.txt"
assert 'the dead verdict comes from the movement rule (no movement to handled)' \
  grep -q 'lane=stalled .*no movement to handled' "$LAB/out-read3.txt"

# =========================================================================
# Scenario: escalation reason names the beat age as its evidence
# =========================================================================
printf '\n########## Scenario: escalate_captain names the stale beat as evidence ##########\n'
run 'ladder plan' bin/fm-lane-recover.sh plan | tee "$LAB/out-plan.txt"
ROW=$(grep '^lane=stalebeat ' "$LAB/out-plan.txt")
printf 'stalebeat escalation row:\n%s\n' "$ROW"
assert 'the plan banner labels the sweep a dry run' grep -q 'mode=dry-run' "$LAB/out-plan.txt"
assert 'the stale-beat lane escalates rather than reporting nothing to do' \
  grep -q 'lane=stalebeat verdict=dead rung=escalate_captain action=would-park' <<<"$ROW"
assert 'the escalation reason names the supervision beat age' \
  grep -q 'supervision beat age' <<<"$ROW"
assert 'the escalation reason says the beat age IS THE EVIDENCE' \
  grep -q 'is the evidence' <<<"$ROW"
assert 'the escalation carries the live probe state of the endpoint' \
  grep -q 'state ambiguous' <<<"$ROW"

# =========================================================================
# Scenario: the off-switch refuses to act and changes nothing
# =========================================================================
printf '\n########## Scenario: RECOVERY=off refuses to act ##########\n'
run 'ladder run with RECOVERY=off' bin/fm-lane-recover.sh run | tee "$LAB/out-run.txt"
assert 'run refuses while the off-switch is off' grep -q 'refusing to act: RECOVERY=off' "$LAB/out-run.txt"
assert 'a refused run degrades to printing the plan' grep -q 'action=would-park' "$LAB/out-run.txt"
assert 'a refused run wrote no ladder log' \
  bash -c '! ls '"$LAB"'/state/.lane-recovery-* 2>/dev/null | grep -q .'
assert 'a refused run consumed no relaunch budget' \
  bash -c '! ls '"$LAB"'/state/.secondmate-relaunch-* 2>/dev/null | grep -q .'
printf 'state dir after the refused run:\n'
ls -A "$LAB/state"

# =========================================================================
# Scenario: routing verification measures routed_unverified
# =========================================================================
printf '\n########## Scenario: routing verification (item 2) ##########\n'
run 'rail routes' bin/fm-lane-liveness.sh routes | tee "$LAB/out-routes.txt"
assert 'the router lane reports 3 claims: 2 routed, 1 routed_unverified' \
  grep -q 'lane lane=router claims=3 routed=2 routed_unverified=1' "$LAB/out-routes.txt"
assert 'the sweep-wide measurement reports the routed_unverified rate' \
  grep -q 'routing-verification claims=11 routed=9 routed_unverified=2 unverified_rate=2/11 (18%)' "$LAB/out-routes.txt"
assert 'the unverified claim is named with its record and corr token' \
  grep -q 'record=003.msg corr=deadbeefdeadbeef verdict=routed_unverified' "$LAB/out-routes.txt"

# =========================================================================
# Scenario: the rail reads a REMOTE lane inbox over the sanctioned ssh path
# =========================================================================
printf '\n########## Scenario: remote lane inbox read over the sanctioned ssh path ##########\n'
# A second lab home whose only lane is the real remote svc-ops lane: the named
# path svc:/home/jon/.firstmate-homes/svc-ops/state/parent-route/svc-ops.inbox.
# The rail reads it from this home over ssh; no local svc-ops.inbox is created.
LAB2=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
bin/fm-lab-home.sh create "$LAB2" >/dev/null || exit 1
cat > "$LAB2/config/response-lanes.conf" <<'EOF'
# lab fixture: one real remote lane, thresholds at defaults
W=900
D=1800
E=600
M=50
SELF=900
lane svc-ops
EOF
cat > "$LAB2/state/svc-ops.meta" <<'EOF'
window=sess:svc-ops
endpoint_task_id=svc-ops
worktree=/home/jon/.firstmate-homes/svc-ops
project=/home/jon/.firstmate-homes/svc-ops
harness=codex
kind=secondmate
mode=secondmate
yolo=off
home=/home/jon/.firstmate-homes/svc-ops
projects=alpha
remote_host=svc
EOF
assert 'no local svc-ops.inbox exists in the lab (a local reading would be meaningless)' \
  test ! -e "$LAB2/state/svc-ops.inbox"
# Direct remote counts by readdir (no glob: the remote login shell is zsh and a
# null_glob'd bare ls would silently list $HOME instead of the inbox).
remote_count() {  # <subdir>
  ssh -o BatchMode=yes -o ConnectTimeout=6 svc \
    "ls -1 /home/jon/.firstmate-homes/svc-ops/state/parent-route/svc-ops.inbox/$1 2>/dev/null | grep -c '\.msg$'"
}
PENDING_BEFORE=$(remote_count .)
HANDLED_BEFORE=$(remote_count handled)
printf 'remote inbox facts (direct readdir over ssh) before the rail read: pending=%s handled=%s\n' \
  "$PENDING_BEFORE" "$HANDLED_BEFORE"
printf '\n'
env FM_HOME="$LAB2" bin/fm-lane-liveness.sh read 2>&1 | tee "$LAB2/out-remote.txt"
PENDING_AFTER=$(remote_count .)
HANDLED_AFTER=$(remote_count handled)
printf 'remote inbox facts after the rail read: pending=%s handled=%s\n' \
  "$PENDING_AFTER" "$HANDLED_AFTER"
ROW=$(grep '^lane=svc-ops ' "$LAB2/out-remote.txt")
printf 'svc-ops remote row:\n%s\n' "$ROW"
assert 'the remote lane is read over ssh, not from a local inbox' \
  grep -q 'lane=svc-ops source=remote:svc' "$LAB2/out-remote.txt"
PENDING=$(printf '%s\n' "$ROW" | sed -n 's/.* pending_count=\([0-9]*\).*/\1/p')
HANDLED=$(printf '%s\n' "$ROW" | sed -n 's/.* handled_count=\([0-9]*\).*/\1/p')
VERDICT=$(printf '%s\n' "$ROW" | sed -n 's/.* verdict=\([^ ]*\).*/\1/p')
assert "the rail's pending depth is bracketed by two direct remote counts ($PENDING_BEFORE <= $PENDING <= $PENDING_AFTER)" \
  test "$PENDING" -ge "$PENDING_BEFORE" -a "$PENDING" -le "$PENDING_AFTER"
assert "the rail's handled depth is bracketed by two direct remote counts ($HANDLED_BEFORE <= $HANDLED <= $HANDLED_AFTER)" \
  test "$HANDLED" -ge "$HANDLED_BEFORE" -a "$HANDLED" -le "$HANDLED_AFTER"
assert "the remote reading is a real non-zero backlog, not a false zero ($PENDING >= 75)" \
  test "$PENDING" -ge 75
assert "the remote lane reaches a real verdict, not unknown (verdict=$VERDICT)" \
  test "$VERDICT" != unknown
assert 'the remote verdict names the unestablished supervision beat it found' \
  grep -q 'supervision beat is unestablished' "$LAB2/out-remote.txt"

# =========================================================================
# Scenario: Jev family (items a and b) - deterministic first, fail-open
# =========================================================================
printf '\n########## Scenario: Jev alert routing and seat-state advice ##########\n'
cat > "$LAB/data/secondmates.md" <<'REG'
- monitor-sre - Watches the monitors. (home: /nope; scope: rails prefixed monitor. or the monitor service itself; projects: monitoring; added 2026-01-01)
- gpu-ops - Watches the GPU host. (home: /nope; scope: all monitoring rails under gpu.*; projects: monitoring; added 2026-01-01)
- svc-ops - Watches svc. (home: /nope; scope: all rails under svc.*; projects: monitoring; added 2026-01-01)
REG
run 'alert-route with an exact namespace match' bin/fm-alert-route.sh monitor.public_url | tee "$LAB/out-alert-exact.txt"
assert 'an exactly matched alert routes clear with no model call' \
  grep -q 'status: clear' "$LAB/out-alert-exact.txt"
assert 'the exact match names the owning charter' grep -q 'owner: monitor-sre' "$LAB/out-alert-exact.txt"
assert 'the exact answer is attributed to exact matching' grep -q 'source: exact' "$LAB/out-alert-exact.txt"
run 'alert-route with an unplaceable alert and no model key' bin/fm-alert-route.sh zzz.nobody.cares | tee "$LAB/out-alert-fallback.txt"
assert 'an unowned alert escalates instead of being dropped (fail open toward paging)' \
  grep -q 'status: escalate' "$LAB/out-alert-fallback.txt"
assert 'the escalation names the fallback owner' grep -q 'owner: captain' "$LAB/out-alert-fallback.txt"
run 'seat-state-advise on an ambiguous endpoint with no model key' \
  bin/fm-seat-state-advise.sh freshbeat | tee "$LAB/out-seat-advise.txt"
assert 'an inconclusive endpoint with the model off fails open toward waiting' \
  grep -q 'advice: healthy_idle' "$LAB/out-seat-advise.txt"
assert 'the advice declares its source fail-open' grep -q 'source: fail-open' "$LAB/out-seat-advise.txt"
assert 'the advice is advisory only' \
  grep -q 'authority: advisory only; never authorizes a relaunch' "$LAB/out-seat-advise.txt"

# =========================================================================
# Scenario: arming the rail registers the check and the rail-silence check
# =========================================================================
printf '\n########## Scenario: arm/disarm wires the heartbeat and silence shims ##########\n'
run 'rail arm' bin/fm-lane-liveness.sh arm | tee "$LAB/out-arm.txt"
assert 'arm registers the verdict-change check shim' test -x "$LAB/state/lane-liveness.check.sh"
assert 'arm registers the rail-silence check shim' test -x "$LAB/state/lane-liveness-self.check.sh"
BEAT_BEFORE=$(stat -c %Y "$LAB/state/.lane-liveness-beat")
printf '\n--- running the registered rail-silence shim while the heartbeat is stale\n'
OUT=$(env FM_HOME="$LAB" "$LAB/state/lane-liveness-self.check.sh" 2>&1)
printf '%s\n' "$OUT"
assert 'the registered silence shim pages while the heartbeat is stale' \
  grep -q 'over SELF=900s' <<<"$OUT"
printf '\n--- running the registered verdict-change shim (completes a sweep)\n'
OUT=$(env FM_HOME="$LAB" "$LAB/state/lane-liveness.check.sh" 2>&1)
printf '%s\n' "$OUT"
BEAT_AFTER=$(stat -c %Y "$LAB/state/.lane-liveness-beat")
assert 'the registered check shim completes a sweep and advances the heartbeat' \
  test "$BEAT_BEFORE" -lt "$BEAT_AFTER"
OUT=$(env FM_HOME="$LAB" "$LAB/state/lane-liveness-self.check.sh" 2>&1)
assert 'the silence shim goes quiet once the check shim has beaten' test -z "$OUT"
run 'rail disarm' bin/fm-lane-liveness.sh disarm
assert 'disarm retires the verdict-change shim' test ! -e "$LAB/state/lane-liveness.check.sh"
assert 'disarm retires the rail-silence shim' test ! -e "$LAB/state/lane-liveness-self.check.sh"

# --- teardown ---------------------------------------------------------------
printf '\n===== teardown\n'
tmux kill-server 2>/dev/null
printf 'lab home contents before removal:\n'
ls -A "$LAB/state"
rm -rf "$LAB"
printf 'lab home removed: %s\n' "$LAB"
rm -rf "$LAB2"
printf 'remote-lane lab home removed: %s\n' "$LAB2"

printf '\nASSERTIONS: total=%s fail=%s\n' "$TOTAL" "$FAILS"
[ "$FAILS" -eq 0 ]
