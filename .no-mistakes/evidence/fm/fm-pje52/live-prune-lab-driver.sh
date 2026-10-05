#!/usr/bin/env bash
# Live prune / accumulation scenarios against a real named fm-lab-* Herdr session.
set -u
ROOT=/home/jon/.no-mistakes/worktrees/46339c0817e0/01M467EPK5PTA3P8KENX9SE2NP
HERDR_LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
fail() { printf 'not ok - %s\n' "$1"; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
REAL_HERDR=$(command -v herdr); HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-live-prune.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"; HOME_DIR="$TMP_ROOT/home"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/config"
touch "$HOME_DIR/config/herdr-presentation-spaces"; printf 'herdr\n' > "$HOME_DIR/config/backend"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name live-prune)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
LOCKER_PID=
cleanup() { local s=$?; [ -n "$LOCKER_PID" ] && kill "$LOCKER_PID" 2>/dev/null
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || s=1
  rm -rf "$TMP_ROOT"; exit "$s"; }
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null || fail provision
# same session-stripping shim as tests/fm-herdr-session-cleanup-e2e.test.sh
sed -n '/^cat > "\$FAKEBIN\/herdr" <<.SH.$/,/^SH$/p' "$ROOT/tests/fm-herdr-session-cleanup-e2e.test.sh" | sed '1d;$d' > "$FAKEBIN/herdr"
chmod +x "$FAKEBIN/herdr"
lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
HOME_P=$(cd "$HOME_DIR" && pwd -P)
S=$HOME_DIR/state
tok() { printf '%-22s' "$1" | tr ' ' x | cut -c1-22; }
label() { printf '└ %s · p:%s' "$1" "$2"; }
v2() { # id token ws
  printf 'version=2\ntask_id=%s\nprojection_id=%s\nhome=%s\nsession=%s\nworkspace_id=%s\ntab_id=%s:t1\npane_id=%s:p1\nparent_workspace_id=w1\nparent_label=firstmate\nworkspace_label=%s\ntask_label=fm-%s\n' \
    "$1" "$2" "$HOME_P" "$HERDR_LAB_SESSION" "$3" "$3" "$3" "$(label "$1" "$2")" "$1" > "$S/$1.herdr-presentation"; }
run_cleanup() { local b=${1:-30}
  FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" FM_HERDR_CLEANUP_BUDGET_SECS=$b \
    PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" "$ROOT/bin/fm-herdr-session-cleanup.sh"; }

lab workspace create --cwd "$ROOT" --label anchor --focus >/dev/null || fail anchor
# A) live projection: workspace carries its token label; meta absent, lock free
TA=$(tok liveA); A=$(lab workspace create --cwd "$ROOT" --label "$(label liveA "$TA")" --no-focus) || fail liveA
WA=$(printf '%s' "$A" | jq -r .result.workspace.workspace_id); v2 liveA "$TA" "$WA"
lab pane run "$(printf '%s' "$A" | jq -r .result.root_pane.pane_id)" "sleep 600" >/dev/null || fail 'busy A'
# A2) stale projection: idle restored shell, label token, meta absent -> positive cleanup must close it
TS=$(tok staleS); SS=$(lab workspace create --cwd "$ROOT" --label "$(label staleS "$TS")" --no-focus) || fail staleS
WS_S=$(printf '%s' "$SS" | jq -r .result.workspace.workspace_id); v2 staleS "$TS" "$WS_S"
# B) live projection whose label was renamed away from the token: only workspace_id ties it
TB=$(tok liveB); B=$(lab workspace create --cwd "$ROOT" --label "renamed by captain" --no-focus) || fail liveB
WB=$(printf '%s' "$B" | jq -r .result.workspace.workspace_id); v2 liveB "$TB" "$WB"
lab pane run "$(printf '%s' "$B" | jq -r .result.root_pane.pane_id)" "sleep 600" >/dev/null || fail 'busy B'
sleep 2
# C) v1 journal with no workspace anywhere
printf 'version=1\ntask_id=oldv1\nprojection_id=%s\n' "$(tok oldv1)" > "$S/oldv1.herdr-presentation"
# D) dead v2 but task meta present
v2 metatask "$(tok metatask)" w999; : > "$S/metatask.meta"
# E) dead v2 but spawn lock held by a live process
v2 lockedtask "$(tok lockedtask)" w998
( FM_HOME="$HOME_DIR"; STATE="$S"; . "$ROOT/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$S/.spawn-lockedtask.lock" || exit 7; touch "$TMP_ROOT/locked"; sleep 300 ) &
LOCKER_PID=$!
for _ in $(seq 50); do [ -e "$TMP_ROOT/locked" ] && break; sleep 0.1; done
[ -e "$TMP_ROOT/locked" ] || fail 'could not hold spawn lock'
# F) N dead v2 journals (accumulated growth)
N=${N:-300}
for i in $(seq "$N"); do v2 "dead$i" "$(tok "dead$i")" "w9$i"; done
echo "journals before: $(ls "$S"/*.herdr-presentation | wc -l)"

echo "--- run 1 (budget 2s, forward progress)"
t0=$(date +%s.%N); run_cleanup 2 2>&1 | tail -3; t1=$(date +%s.%N)
left1=$(ls "$S"/dead*.herdr-presentation 2>/dev/null | wc -l)
printf 'wall=%.2fs dead-left=%s/%s\n' "$(echo "$t1-$t0" | bc)" "$left1" "$N"
awk "BEGIN{exit !($t1-$t0 < 6)}" || fail 'run 1 exceeded its 2s budget plus grace'
[ "$left1" -lt "$N" ] || fail 'run 1 made no forward progress'
pass "budget-bounded run stays within bound and prunes some dead journals ($((N-left1)) of $N)"

echo "--- repeated runs until all dead pruned (budget 30s)"
for r in 2 3 4 5 6 7 8 9 10; do
  t0=$(date +%s.%N); run_cleanup 30 2>&1 | tail -2; t1=$(date +%s.%N)
  left=$(ls "$S"/dead*.herdr-presentation 2>/dev/null | wc -l)
  printf 'run %s wall=%.2fs dead-left=%s\n' "$r" "$(echo "$t1-$t0" | bc)" "$left"
  [ "$left" -eq 0 ] && break
done
[ "$left" -eq 0 ] || fail 'dead journals never fully pruned'
pass 'accumulated dead v2 journals fully pruned across bounded runs'

[ ! -f "$S/staleS.herdr-presentation" ] || fail 'stale idle projection journal survived'
if lab workspace get "$WS_S" >/dev/null 2>&1; then fail 'stale idle projection workspace survived'; fi
pass 'positive cleanup still closes the stale idle projection and removes its journal amid 300 dead journals'
[ -f "$S/liveA.herdr-presentation" ] || fail 'live labelled projection journal was pruned'
[ -f "$S/liveB.herdr-presentation" ] || fail 'live renamed projection journal was pruned'
lab workspace get "$WA" >/dev/null || fail 'live workspace A was closed'
lab workspace get "$WB" >/dev/null || fail 'live workspace B was closed'
pass 'live projection journals (label match and workspace-id-only match) and workspaces survive'
[ -f "$S/oldv1.herdr-presentation" ] || fail 'v1 journal was pruned'
pass 'v1 journal (liveness unprovable) survives'
[ -f "$S/metatask.herdr-presentation" ] || fail 'journal with task meta was pruned'
pass 'dead v2 journal with task meta present survives'
[ -f "$S/lockedtask.herdr-presentation" ] || fail 'journal with held spawn lock was pruned'
pass 'dead v2 journal whose spawn lock is held survives'
kill "$LOCKER_PID"; wait "$LOCKER_PID" 2>/dev/null; LOCKER_PID=
