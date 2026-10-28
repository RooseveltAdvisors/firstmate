#!/usr/bin/env bash
# Live fm-v0kjm drive of the supervision-host path (non-Pi primary): a lab copy
# of this checkout opted into the host, a real away-posture wake produced by a
# real status append through the real watcher, and a real headless Claude Code
# engine turn under the branch contract. Adapted from the repo's own opt-in
# guard tests/fm-supervision-host-live-e2e.test.sh (the lock holder is a bash
# named claude; tmux is a stub that fails so no real tmux server is touched).
# Usage: run-host-turn.sh <code-root> <evidence-dir>
set -u
ROOT=$1 EV=$2
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-v0kjm-host.XXXXXX")
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
git -C "$ROOT" ls-files -z -co --exclude-standard | (cd "$ROOT" && tar --null -T - -cf -) | (cd "$LAB" && tar -xf -)
git -C "$LAB" init -q -b main && git -C "$LAB" add -A >/dev/null \
  && git -C "$LAB" -c user.name=fmlab -c user.email=fmlab@example.invalid commit -q -m lab
mkdir -p "$LAB/state" "$LAB/config" "$WORK/harness" "$WORK/tmuxbin"
ln -s /bin/bash "$WORK/harness/claude"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/tmuxbin/tmux"; chmod +x "$WORK/tmuxbin/tmux"
: > "$LAB/config/supervision-host"
printf 'project=g2jj0\nwindow=fm-fm-g2jj0\nharness=claude\n' > "$LAB/state/fm-g2jj0.meta"

stop_lab() {
  local pid
  pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$LAB/state/.supervision-host" 2>/dev/null)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null
  sleep 2
  pid=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null); [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null
  pid=$(cat "$WORK/primary.pid" 2>/dev/null); [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null
  pkill -f "$LAB/" 2>/dev/null || true
  rm -rf "$LAB" "$WORK"
}
trap stop_lab EXIT

labenv() {
  env -i HOME="$HOME" PATH="$WORK/tmuxbin:$PATH" USER="${USER:-jon}" LANG=C.UTF-8 TERM=xterm-256color SHELL=/bin/bash \
    FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@"
}
labenv "$LAB/bin/fm-afk-contract.sh" enter --words 'Watch the fleet. If fm-g2jj0 is blocked waiting on a steer, claim its lease, steer it once with bin/fm-send.sh fm-g2jj0 "carry on with the migration", release its lease, and report the outcome. Merge nothing and dispatch nothing.' >/dev/null \
  || { echo "could not record the away posture"; exit 1; }

labenv "$WORK/harness/claude" -c '
  printf "%s\n" "$$" > "$FM_HOME/state/.lock"
  printf "%s\n" "$$" > "$1/primary.pid"
  "$FM_HOME/bin/fm-supervision-host.sh" park > "$1/host.out" 2>&1
  printf "%s\n" "$?" > "$1/host.rc"
' _ "$WORK" 2>> "$WORK/harness.err" &

wait_until() { local limit=$1 i=0; shift; while [ "$i" -lt "$limit" ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }
watcher_live() { local pid; pid=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null) || return 1; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
settled() { grep -qE '	(handled|failed)	' "$LAB/state/.supervision-host.log" 2>/dev/null || [ -s "$WORK/host.rc" ]; }
wait_until 300 watcher_live || { echo "HOST_FAIL no watcher"; cat "$WORK/host.out"; exit 1; }
LOCK=$(cat "$LAB/state/.lock")
echo "lab=$LAB lock-holder=$LOCK claude=$(claude --version 2>/dev/null | head -n1)"

printf 'blocked [at=%s]: waiting on a steer from firstmate - confirm I should carry on with the migration\n' "$(date +%s)" >> "$LAB/state/fm-g2jj0.status"
# Poll through the engine turn: capture the branch lease the moment it exists,
# its read-only verdict, and the host turn record it is bound to.
SEEN=0
for _ in $(seq 1 9000); do
  if [ "$SEEN" = 0 ] && [ -e "$LAB/state/.lease-fm-g2jj0" ]; then
    {
      printf 'lease-line: %s\n' "$(tr '\t' '|' < "$LAB/state/.lease-fm-g2jj0")"
      printf 'check: %s\n' "$(labenv "$LAB/bin/fm-lease.sh" check fm-g2jj0 2>&1)"
      printf 'host-turn-record: %s\n' "$(sed -n 1p "$LAB/state/.supervision-host-turn" 2>/dev/null || echo absent)"
    } > "$WORK/mid-turn.txt"
    SEEN=1
  fi
  settled && break
  sleep 0.05
done
wait_until 50 false
{
  echo "== mid-turn capture"; cat "$WORK/mid-turn.txt" 2>/dev/null || echo "(the engine never claimed fm-g2jj0's lease)"
  echo "== after the turn"
  printf 'lease file: %s\n' "$( [ -e "$LAB/state/.lease-fm-g2jj0" ] && tr '\t' '|' < "$LAB/state/.lease-fm-g2jj0" || echo absent)"
  printf 'host turn record: %s\n' "$( [ -e "$LAB/state/.supervision-host-turn" ] && cat "$LAB/state/.supervision-host-turn" || echo absent)"
  echo "== host ledger"; cut -f1-6 "$LAB/state/.supervision-host.log" 2>/dev/null
  echo "== outcome store"; cat "$LAB/state/branch-outcomes.jsonl" 2>/dev/null
  echo "== steering inbox"; find "$LAB/state/fm-g2jj0.inbox" -name '*.msg' -exec sh -c 'for f; do echo "-- $f"; sed -n "/^--$/,\$p" "$f"; done' _ {} + 2>/dev/null
  echo "== main woken?"; printf 'host.rc=%s\n' "$(cat "$WORK/host.rc" 2>/dev/null || echo none-still-parked)"
} > "$WORK/host-report.txt"
SESSION=$(sed -n 's/^session=//p' "$LAB/state/.supervision-host-engine" 2>/dev/null)
PROJ="$HOME/.claude/projects/$(printf '%s' "$LAB" | sed 's#[/.]#-#g')/$SESSION.jsonl"
if [ -n "$SESSION" ] && [ -f "$PROJ" ]; then
  echo "== engine Bash commands (from the engine's own Claude transcript $SESSION)" >> "$WORK/host-report.txt"
  jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and .name=="Bash") | .input.command' "$PROJ" >> "$WORK/host-report.txt" 2>/dev/null
fi
cp "$WORK/host-report.txt" "$EV/host-live-turn-report.txt"
cat "$WORK/host-report.txt"
