#!/usr/bin/env bash
# Live fm-v0kjm drive on a real Pi SDK primary in a disposable lab home.
# Usage: run-pi-incident.sh <target|base> <code-root> <evidence-dir>
set -u
MODE=$1 CODE_ROOT=$2 EV=$3
H=$(cd "$(dirname "$0")" && pwd)
PI_RELEASE=$HOME/.pi/agent/install/releases/$(cat "$HOME/.pi/agent/install/current-version")
PI_PKG=$PI_RELEASE/node_modules/@earendil-works/pi-coding-agent
PI_VERSION=$(node -p "require('$PI_PKG/package.json').version")
TASK=fm-g2jj0

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-v0kjm-live-$MODE.XXXXXX")
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$CODE_ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$LAB/tmux"
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  [ -n "${A_PID:-}" ] && kill "$A_PID" 2>/dev/null
  pkill -f "$WORK/" 2>/dev/null || true
  rm -rf "$LAB" "$WORK"
}
trap cleanup EXIT

# The crewmate endpoint for fm-g2jj0: a pane in the lab's private tmux server.
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s fmlab -n "fm-$TASK" -x 160 -y 40 cat
SOCK=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display -p -t fmlab '#{socket_path},#{pid},#{session_id}')
LAB_TMUX="${SOCK%\$*}${SOCK##*\$}"
mkdir -p "$LAB/projects/g2jj0"
printf 'project=%s\nwindow=fmlab:fm-%s\nbackend=tmux\nharness=claude\n' "$LAB/projects/g2jj0" "$TASK" > "$LAB/state/$TASK.meta"

# Fixture: the code root's own Pi extensions, resolvable against the real Pi
# release's node_modules (the repo live-probe layout), plus the stub watcher arm.
FIX=$WORK/fixture
mkdir -p "$FIX/.pi/extensions/lib" "$FIX/bin" "$WORK/main-agent" "$WORK/branch-agent" "$WORK/secondary-agent" "$WORK/home" "$WORK/main-sessions" "$WORK/secondary-sessions"
cp "$CODE_ROOT/.pi/extensions/fm-branch-supervision.ts" "$CODE_ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$FIX/.pi/extensions/"
for f in "$CODE_ROOT"/.pi/extensions/lib/*.ts; do cp -L "$f" "$FIX/.pi/extensions/lib/" 2>/dev/null || true; done
ln -s "$PI_RELEASE/node_modules" "$FIX/node_modules"
cp "$H/watch-arm-stub.sh" "$FIX/bin/fm-watch-arm.sh"
cp "$CODE_ROOT/bin/fm-operational-input.sh" "$FIX/bin/"
chmod +x "$FIX/bin/"*.sh

LOGF=$WORK/driver.log
labenv() {
  env -i HOME="$WORK/home" PATH="$PATH" USER="${USER:-jon}" LANG=C.UTF-8 TMPDIR="${TMPDIR:-/tmp}" SHELL=/bin/bash TERM=xterm-256color \
    NODE_NO_WARNINGS=1 FM_HOME="$LAB" TMUX="$LAB_TMUX" TMUX_TMPDIR="$LAB/tmux" \
    CODE_ROOT="$CODE_ROOT" FIXTURE="$FIX" WORK="$WORK" MODE="$MODE" DRIVER_LOG="$LOGF" PI_PKG="$PI_PKG" PI_VERSION="$PI_VERSION" \
    FM_LIVE_WATCH_LOG="$WORK/watch.log" FM_LIVE_WATCH_TRIGGER="$WORK/watch.trigger" "$@"
}
echo "mode=$MODE code-root=$CODE_ROOT pi=$PI_VERSION lab=$LAB"
labenv PI_CODING_AGENT_DIR="$WORK/branch-agent" node "$H/pi-primary-driver.mjs" > "$WORK/driver.out" 2>&1 &
A_PID=$!
# The second Pi session is started from here, so it is NOT in the primary's
# process ancestry (it cannot own the fleet lock), while the owner's branch
# is mid-turn on wake 3.
for _ in $(seq 1 1800); do
  [ -e "$WORK/mid-turn-3" ] && break
  kill -0 "$A_PID" 2>/dev/null || break
  sleep 0.1
done
if [ -e "$WORK/mid-turn-3" ]; then
  cp "$WORK/main-agent/models.json" "$WORK/secondary-agent/models.json"
  labenv PI_CODING_AGENT_DIR="$WORK/secondary-agent" node "$H/pi-secondary-driver.mjs" > "$WORK/secondary.out" 2>&1 \
    || echo "secondary-failed $(cat "$WORK/secondary.out")" > "$WORK/secondary-done"
fi
wait "$A_PID"
RC=$?
A_PID=
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t "fmlab:fm-$TASK" > "$WORK/crewmate-pane.txt" 2>/dev/null || true
ls -la "$LAB/state/" > "$WORK/lab-state-listing.txt" 2>&1
find "$LAB/state/$TASK.inbox" -type f -exec sh -c 'for f; do echo "== $f"; cat "$f"; echo; done' _ {} + > "$WORK/inbox-records.txt" 2>/dev/null || true
for f in driver.out driver.log watch.log secondary.out crewmate-pane.txt lab-state-listing.txt inbox-records.txt observations.json; do
  [ -e "$WORK/$f" ] && cp "$WORK/$f" "$EV/pi-live-$MODE-$f"
done
cat "$WORK/driver.out"
exit "$RC"
