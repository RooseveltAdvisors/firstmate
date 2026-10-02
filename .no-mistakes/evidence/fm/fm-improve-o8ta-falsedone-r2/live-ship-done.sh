#!/usr/bin/env bash
# Live driver: part 2 of the change - require a PR before ship done.
# Drives the REAL products end-to-end in disposable fixtures:
#   1. bin/fm-crew-state.sh current-state reads for a ship worker's status log
#   2. bin/fm-inactive-reconcile.sh ledger delivery to the parent channel
#   3. bin/fm-brief.sh generated ship Definition-of-done contract
# plus the base commit's scripts as the fail-before contrast.
# External tools (tmux on a private socket, forge CLIs) are fixtures; every
# firstmate script under test is the real one from the given bin dir.
#
# Usage: live-dod.sh <bin-dir-under-test> <label> [--with-base-contrast]
set -u

ROOT=/home/jon/.no-mistakes/worktrees/2f32188048b1/01M3XNRZQKW563WQCGY4XH4RVF
EVD=/home/jon/.no-mistakes/evidence/01M3XNRZQKW563WQCGY4XH4RVF
BIN=${1:?bin dir under test}
LABEL=${2:?label}
CONTRAST=${3:-}
REAL_TMUX=$(command -v tmux) || { echo "tmux missing"; exit 2; }

FAILURES=0
fail() { printf '[%s] FAIL: %s\n' "$LABEL" "$*"; FAILURES=$((FAILURES + 1)); }
expect_eq() { [ "$1" = "$2" ] || fail "$3 (got '$1', want '$2')"; }
expect_in() { case "$2" in *"$1"*) ;; *) fail "$3 (missing: $1)";; esac; }
expect_not_in() { case "$2" in *"$1"*) fail "$3 (unexpected: $1)";; *) ;; esac; }

TMPW=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-dod.XXXXXX") || exit 2
LOG="$EVD/live-ship-done.$LABEL.log"
: > "$LOG"
export TMUX_TMPDIR="$TMPW/tmux"
mkdir -p "$TMUX_TMPDIR" "$TMPW/bin" "$TMPW/nm"

cleanup() {
  "$TMPW/bin/tmux" kill-server 2>/dev/null || true
  rm -rf "$TMPW"
}
trap cleanup EXIT

cat > "$TMPW/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -L fm-dod "\$@"
EOF
chmod +x "$TMPW/bin/tmux"
# Panes whose foreground command reads as a live agent (codex), matching a
# production crew terminal for the pane reads both products perform.
mkdir -p "$TMPW/agent"
ln -s "$(command -v bash)" "$TMPW/agent/codex"
# Hermetic forge CLIs: any call is logged and refused, so the fixtures prove the
# product made no network/forge claims of its own.
for tool in gh gh-axi glab gerrit-axi curl; do
  cat > "$TMPW/bin/$tool" <<'SH'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >> "${FM_FORGE_LOG:?}"
exit 97
SH
  chmod +x "$TMPW/bin/$tool"
done
: > "$TMPW/forge.log"
export FM_FORGE_LOG="$TMPW/forge.log"

run_crew_state() { # <bin-under-test> <case-dir> <id>
  cd "$2" || return 1
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
      PATH="$TMPW/bin:$PATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
      FM_HOME="$2" FM_STATE_OVERRIDE="$2/state" FM_BACKEND=tmux \
      FM_CREW_STATE_NO_FORGE=1 NM_HOME="$TMPW/nm" \
      "$1/fm-crew-state.sh" "$3" 2>&1
}

arm_idle() { # <case-dir> <id>
  local gen
  gen=$("$BIN/fm-busy-event.sh" arm "$1/state" "$2")
  "$BIN/fm-busy-event.sh" apply "$1/state" "$2" idle --gen "$gen" \
    --source claude-hook --event stop
}

mkpanes() { # <window>...
  local first=$1; shift
  "$TMPW/bin/tmux" new-session -d -s firstmate -n "$first" "$TMPW/agent/codex --norc" 2>/dev/null \
    || "$TMPW/bin/tmux" new-window -d -t 'firstmate:' -n "$first" "$TMPW/agent/codex --norc"
  for w in "$@"; do "$TMPW/bin/tmux" new-window -d -t 'firstmate:' -n "$w" "$TMPW/agent/codex --norc"; done
  sleep 0.3; }

# ===========================================================================
# 1) crew-state: how a ship worker's status-log claim reads as CURRENT state
# ===========================================================================
export GIT_AUTHOR_NAME=livetest GIT_AUTHOR_EMAIL=livetest@example.invalid
export GIT_COMMITTER_NAME=livetest GIT_COMMITTER_EMAIL=livetest@example.invalid

D="$TMPW/crew"
mkdir -p "$D/state"
git init -q "$D/wt"
git -C "$D/wt" commit -q --allow-empty -m init
git -C "$D/wt" checkout -q -b fm/task1
git -C "$D/wt" update-ref refs/remotes/origin/main "$(git -C "$D/wt" rev-parse HEAD)"
HEAD1=$(git -C "$D/wt" rev-parse HEAD)
cat > "$D/state/task1.meta" <<EOF
window=firstmate:fm-task1
worktree=$D/wt
project=$D/wt
kind=ship
mode=no-mistakes
harness=claude
EOF
mkpanes fm-task1
arm_idle "$D" task1

# Case 1 (core): bare no-mistakes summary claims done -> blocked, claim visible
printf 'done: implementation complete\n' > "$D/state/task1.status"
out=$(run_crew_state "$BIN" "$D" task1); rc=$?
printf -- '--- crew-state target case1 bare done (rc=%s)\n%s\n' "$rc" "$out" >> "$LOG"
expect_in "state: blocked" "$out" "case1: bare no-mistakes done must read blocked"
expect_not_in "state: done" "$out" "case1: bare summary must not read as terminal done"
expect_in "done: implementation complete" "$out" "case1: refused claim stays visible"

# Case 2 (positive control): CI-ready report with the head pushed -> done
printf 'done: PR https://github.com/o/r/pull/7 checks green\n' > "$D/state/task1.status"
out=$(run_crew_state "$BIN" "$D" task1); rc=$?
printf -- '--- crew-state target case2 CI-ready pushed head (rc=%s)\n%s\n' "$rc" "$out" >> "$LOG"
expect_in "state: done" "$out" "case2: CI-ready done with pushed head must read done"
expect_not_in "state: blocked" "$out" "case2: validated delivery must not be blocked"

# Case 3 (adversarial): CI-ready report but HEAD unpushed -> still blocked
git -C "$D/wt" commit -q --allow-empty -m 'fix never pushed'
printf 'done: PR https://github.com/o/r/pull/7 checks green\n' > "$D/state/task1.status"
out=$(run_crew_state "$BIN" "$D" task1); rc=$?
printf -- '--- crew-state target case3 CI-ready unpushed head (rc=%s)\n%s\n' "$rc" "$out" >> "$LOG"
expect_in "state: blocked" "$out" "case3: unpushed head must stay blocked"
expect_in "unreachable outside the worker copy" "$out" "case3: refusal names the unpushed head"

# Case 4 (adversarial): bare summary WITH a recorded PR and pr_head on the forge
cat > "$D/state/task1.meta" <<EOF
window=firstmate:fm-task1
worktree=$D/wt
project=$D/wt
kind=ship
mode=no-mistakes
harness=claude
pr=https://github.com/o/r/pull/7
pr_head=$(git -C "$D/wt" rev-parse HEAD)
EOF
printf 'done: implementation complete\n' > "$D/state/task1.status"
out=$(run_crew_state "$BIN" "$D" task1); rc=$?
printf -- '--- crew-state target case4 bare done with recorded PR (rc=%s)\n%s\n' "$rc" "$out" >> "$LOG"
expect_in "state: blocked" "$out" "case4: bare summary must be blocked even with a recorded PR"
expect_in "reports no validated no-mistakes delivery" "$out" "case4: refusal names the missing validation"

# ===========================================================================
# 2) inactive-reconcile: what reaches the parent channel as a terminal outcome
# ===========================================================================
reconcile_world() { # <dir>
  local w=$1
  mkdir -p "$w/main/state" "$w/main/data" "$w/main/config" "$w/main/projects"
  mkdir -p "$w/mate/state" "$w/mate/data" "$w/mate/config" "$w/mate/projects" "$w/mate/bin"
  : > "$w/mate/AGENTS.md"
  printf 'mate\n' > "$w/mate/.fm-secondmate-home"
  cat > "$w/mate/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$w/main
EOF
}

write_child() { # <mate-home> <id> <status>
  local home=$1 id=$2 status=$3 sha
  mkdir -p "$home/projects/$id"
  git init -q "$home/projects/$id"
  git -C "$home/projects/$id" commit -q --allow-empty -m init
  sha=$(git -C "$home/projects/$id" rev-parse HEAD)
  git -C "$home/projects/$id" update-ref refs/remotes/origin/main "$sha"
  cat > "$home/state/$id.meta" <<EOF
window=firstmate:fm-$id
worktree=$home/projects/$id
project=$home/projects/$id
harness=codex
kind=ship
mode=no-mistakes
yolo=off
spawn_gen=live.$RANDOM
pr=https://example.test/owner/repo/pull/1
pr_head=$sha
EOF
  printf '%s\n' "$status" > "$home/state/$id.status"
  : > "$home/state/$id.turn-ended"
  touch -d '150 seconds ago' "$home/state/$id.meta" "$home/state/$id.status" "$home/state/$id.turn-ended"
}

run_reconcile() { # <bin-under-test> <world>
  cd "$2/mate" || return 1
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
      PATH="$TMPW/bin:$PATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
      FM_HOME="$2/mate" FM_ROOT_OVERRIDE="$2/root" \
      FM_INACTIVE_RECONCILE_SECS=60 NM_HOME="$TMPW/nm" \
      "$1/fm-inactive-reconcile.sh" scan 2>&1
}

parent_status() { cat "$1/main/state/mate.status" 2>/dev/null || true; }

RW="$TMPW/recon-target"
mkdir -p "$RW/root"
reconcile_world "$RW"
write_child "$RW/mate" bare 'done: implementation complete'
write_child "$RW/mate" ready 'done: PR https://example.test/owner/repo/pull/1 checks green'
mkpanes fm-bare fm-ready
sleep 0.3
out=$(run_reconcile "$BIN" "$RW"); rc=$?
ps=$(parent_status "$RW")
printf -- '--- reconcile target scan (rc=%s)\n%s\n--- parent channel:\n%s\n' "$rc" "$out" "$ps" >> "$LOG"
expect_in "child ready done:" "$ps" "reconcile: CI-ready child must be delivered upstream (positive control)"
expect_not_in "child bare done:" "$ps" "reconcile: bare no-mistakes done must never reach the parent channel"
bare_receipts=$(grep -l "task_id=bare" "$RW/mate/state/terminal-outcomes"/*.reported 2>/dev/null | wc -l | tr -d ' ')
expect_eq "$bare_receipts" 0 "reconcile: no terminal receipt may be minted for the bare summary"
ready_receipts=$(grep -l "task_id=ready" "$RW/mate/state/terminal-outcomes"/*.reported 2>/dev/null | wc -l | tr -d ' ')
expect_eq "$ready_receipts" 1 "reconcile: the CI-ready child keeps its delivery receipt"

# Positive control inside the same child: once the claim becomes CI-ready it is delivered
printf 'done: PR https://example.test/owner/repo/pull/1 checks green\n' > "$RW/mate/state/bare.status"
touch -d '150 seconds ago' "$RW/mate/state/bare.status"
out=$(run_reconcile "$BIN" "$RW"); rc=$?
ps=$(parent_status "$RW")
printf -- '--- reconcile target rescan after CI-ready claim (rc=%s)\n--- parent channel:\n%s\n' "$rc" "$ps" >> "$LOG"
expect_in "child bare done:" "$ps" "reconcile: the same child becomes deliverable once its done is CI-ready"

# ===========================================================================
# 3) generated ship Definition of done (fm-brief.sh) - the worker-facing contract
# ===========================================================================
gen_brief() { # <bin-under-test> <home> <id> <mode> [forge args...]
  local bin=$1 home=$2 id=$3 mode=$4; shift 4
  mkdir -p "$home/data"
  cd "$home" || return 1
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS PATH="$TMPW/bin:$PATH" \
    FM_HOME="$home" "$bin/fm-brief.sh" "$id" some-proj --mode "$mode" "$@" >/dev/null 2>&1 \
    && printf '%s/data/%s/brief.md\n' "$home" "$id"
}

BW="$TMPW/briefs-target"
p=$(gen_brief "$BIN" "$BW" brief-nm no-mistakes); rc=$?
[ -n "$p" ] || { fail "brief: no-mistakes brief did not scaffold"; p=/dev/null; }
nm=$(cat "$p" 2>/dev/null || true)
printf -- '--- generated no-mistakes brief:\n%s\n' "$nm" >> "$LOG"
expect_in "Delivery contract: mode=no-mistakes" "$nm" "brief nm: machine-readable contract line"
expect_in "complete only after the branch is pushed and a PR is open with checks green (or attestation green)" "$nm" "brief nm: requires pushed branch + open PR + checks/attestation green"
expect_in "A commit is only the input to validation; never report done from the bare implementation commit" "$nm" "brief nm: a commit is validation input only"
expect_in "until the pipeline reports CI green" "$nm" "brief nm: no done: before CI green"
expect_not_in "is the handoff that starts the pipeline" "$nm" "brief nm: no pre-validation handoff done:"
expect_not_in "The task is complete only when committed on your branch" "$nm" "brief nm: bare commit is never complete"

p=$(gen_brief "$BIN" "$BW" brief-direct direct-PR); rc=$?
[ -n "$p" ] || { fail "brief: direct-PR brief did not scaffold"; p=/dev/null; }
dp=$(cat "$p" 2>/dev/null || true)
printf -- '--- generated direct-PR brief (definition of done):\n%s\n' "$(printf '%s\n' "$dp" | sed -n '/# Definition of done/,/^$/p')" >> "$LOG"
expect_in "complete only after the branch is pushed and a PR is open" "$dp" "brief direct-PR: requires pushed branch + open PR"
expect_not_in "The task is complete only when committed on your branch" "$dp" "brief direct-PR: committed-on-branch alone is not complete"

p=$(gen_brief "$BIN" "$BW" brief-gerrit no-mistakes --forge gerrit --shape squash); rc=$?
[ -n "$p" ] || { fail "brief: gerrit no-mistakes brief did not scaffold"; p=/dev/null; }
gn=$(cat "$p" 2>/dev/null || true)
printf -- '--- generated gerrit no-mistakes brief (definition of done):\n%s\n' "$(printf '%s\n' "$gn" | sed -n '/# Definition of done/,/^$/p')" >> "$LOG"
expect_in "complete only after the run's outcome passes and the change is published for review" "$gn" "brief gerrit nm: run outcome + published change"
expect_in "A commit is only the input to validation; never report done from the bare implementation commit" "$gn" "brief gerrit nm: commit is validation input only"
expect_not_in "is the handoff that starts the pipeline" "$gn" "brief gerrit nm: no pre-validation handoff done:"
expect_not_in "The task is complete only when committed on your branch" "$gn" "brief gerrit nm: committed-on-branch alone is not complete"

p=$(gen_brief "$BIN" "$BW" brief-dpg direct-PR --forge gerrit --shape squash); rc=$?
[ -n "$p" ] || { fail "brief: direct-PR gerrit brief did not scaffold"; p=/dev/null; }
dpg=$(cat "$p" 2>/dev/null || true)
expect_in "complete only after the branch is pushed and the change is open" "$dpg" "brief direct-PR gerrit: requires pushed + open change"
expect_not_in "The task is complete only when committed on your branch" "$dpg" "brief direct-PR gerrit: committed-on-branch alone is not complete"

# ===========================================================================
# Fail-before contrast: the base commit's scripts in the same fixtures
# ===========================================================================
if [ "$CONTRAST" = "--with-base-contrast" ]; then
  # Recreate the base scripts for the fail-before contrast with:
  #   mkdir -p <dir>/base-bin && git archive 8690c411 bin | tar -x -C <dir>/base-bin
  BASEBIN="${BASE_BIN:-$EVD/base-bin/bin}"
  [ -x "$BASEBIN/fm-crew-state.sh" ] || { echo "base bin missing: $BASEBIN (set BASE_BIN)"; exit 2; }
  # crew-state base: bare summary used to read terminal done (original no-pr meta)
  cat > "$D/state/task1.meta" <<EOF
window=firstmate:fm-task1
worktree=$D/wt
project=$D/wt
kind=ship
mode=no-mistakes
harness=claude
EOF
  printf 'done: implementation complete\n' > "$D/state/task1.status"
  out=$(run_crew_state "$BASEBIN" "$D" task1); rc=$?
  printf -- '--- crew-state BASE case1 bare done (rc=%s)\n%s\n' "$rc" "$out" >> "$LOG"
  expect_in "state: done" "$out" "base case1 (fail-before): bare summary used to read done"

  # reconcile base: bare summary used to reach the parent channel
  RW2="$TMPW/recon-base"
  mkdir -p "$RW2/root"
  reconcile_world "$RW2"
  write_child "$RW2/mate" bare 'done: implementation complete'
  write_child "$RW2/mate" ready 'done: PR https://example.test/owner/repo/pull/1 checks green'
  out=$(run_reconcile "$BASEBIN" "$RW2"); rc=$?
  ps=$(parent_status "$RW2")
  printf -- '--- reconcile BASE scan (rc=%s)\n--- parent channel:\n%s\n' "$rc" "$ps" >> "$LOG"
  expect_in "child bare done:" "$ps" "base reconcile (fail-before): bare summary used to be published upstream"

  # brief base: the contract used to order a handoff done: from the bare commit
  BWB="$TMPW/briefs-base"
  p=$(gen_brief "$BASEBIN" "$BWB" brief-nm no-mistakes); rc=$?
  bnm=$(cat "$p" 2>/dev/null || true)
  printf -- '--- BASE no-mistakes brief (definition of done):\n%s\n' "$(printf '%s\n' "$bnm" | sed -n '/# Definition of done/,/^$/p')" >> "$LOG"
  expect_in "is the handoff that starts the pipeline" "$bnm" "base brief (fail-before): contract used to order a handoff done:"
  expect_in "The task is complete only when committed on your branch" "$bnm" "base brief (fail-before): committed-on-branch used to be complete"
fi

if [ "$FAILURES" -eq 0 ]; then
  printf '[%s] ALL PASS\n' "$LABEL"
else
  printf '[%s] %s FAILURES\n' "$LABEL" "$FAILURES"
  exit 1
fi
