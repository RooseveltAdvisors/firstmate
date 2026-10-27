#!/usr/bin/env bash
# Live validation driver for fm-av46m (worktree reaper reference gate).
# Drives the real bin/fm-jev-worktree-reaper.sh end-to-end against disposable
# git repos and homes under /tmp/fm-reaper-live. Nothing outside that fixture
# root is read or written (HOME, FM_HOME, FM_SECONDMATE_HOMES_DIR and
# TREEHOUSE_ROOT are always pointed at the fixture).
set -uo pipefail

EV=/home/jon/.no-mistakes/evidence/01M5W8MN7RQG9DM97H18YREYRF
RUN=/home/jon/.no-mistakes/worktrees/46339c0817e0/01M5W8MN7RQG9DM97H18YREYRF
WRAP="$RUN/bin/fm-jev-worktree-reaper.sh"
FIX=/tmp/fm-reaper-live
rm -rf "$FIX"
mkdir -p "$FIX"
FAILS=0

note() { echo "  $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "  ok: $*"; }

# Fresh disposable repo with one clean merged worktree at main's tip.
new_repo() {
  local name="$1"
  mkdir -p "$FIX/$name"
  git -C "$FIX/$name" init -q -b main repo
  git -C "$FIX/$name/repo" config user.name "Live Validation"
  git -C "$FIX/$name/repo" config user.email "live@example.com"
  echo init > "$FIX/$name/repo/README.md"
  git -C "$FIX/$name/repo" add README.md
  git -C "$FIX/$name/repo" commit -qm init
  echo feature > "$FIX/$name/repo/feature.txt"
  git -C "$FIX/$name/repo" add feature.txt
  git -C "$FIX/$name/repo" commit -qm feature
}

new_home() {
  mkdir -p "$1/state" "$1/data"
}

# A confidently-readable process table: one foreign pid whose cwd and fds are
# readable and outside every candidate. Needed wherever the scenario asserts a
# reap: real /proc on this host has foreign-owned pids the probe cannot read
# (doubt -> keep), so only the product's own seam can prove a confident zero.
new_proc_clean() {
  mkdir -p "$1/1000/fd"
  ln -s / "$1/1000/cwd"
  printf 'Uid:\t1000\t1000\t1000\t1000\n' > "$1/1000/status"
}

# ---------------------------------------------------------------------------
echo "=== S1: unreferenced merged clean worktree is still reaped ==="
{
  new_repo s1
  new_home "$FIX/s1/home"
  mkdir -p "$FIX/s1/user-home" "$FIX/s1/homes"
  WT="$FIX/s1/wt-unreferenced"
  git -C "$FIX/s1/repo" worktree add -q --detach "$WT" main
  new_proc_clean "$FIX/s1/proc-clean"
  OUT="$FIX/s1/out.log"
  env HOME="$FIX/s1/user-home" FM_HOME="$FIX/s1/home" FM_SECONDMATE_HOMES_DIR="$FIX/s1/homes" \
    FM_PROC_ROOT_OVERRIDE="$FIX/s1/proc-clean" \
    "$WRAP" --repo-dir "$FIX/s1/repo" --base-branch main > "$OUT" 2>&1
  RC=$?
  cat "$OUT"
  [ $RC -eq 0 ] && pass "exit 0" || fail "exit code $RC"
  grep -q "Reaped: ${WT} " "$OUT" && pass "reported as Reaped" || fail "not reported as Reaped"
  [ ! -d "$WT" ] && pass "worktree directory removed" || fail "worktree still present"
  cp "$OUT" "$EV/scenario-1-unreferenced-reaped.log"
}

# ---------------------------------------------------------------------------
echo "=== S2: task-record-referenced merged clean worktree is preserved ==="
{
  new_repo s2
  new_home "$FIX/s2/home"
  mkdir -p "$FIX/s2/user-home" "$FIX/s2/homes"
  WT="$FIX/s2/wt-task-referenced"
  git -C "$FIX/s2/repo" worktree add -q --detach "$WT" main
  printf 'worktree=%s\n' "$WT" > "$FIX/s2/home/state/fm-live-task.meta"
  OUT="$FIX/s2/out.log"
  env HOME="$FIX/s2/user-home" FM_HOME="$FIX/s2/home" FM_SECONDMATE_HOMES_DIR="$FIX/s2/homes" \
    "$WRAP" --repo-dir "$FIX/s2/repo" --base-branch main > "$OUT" 2>&1
  RC=$?
  cat "$OUT"
  [ $RC -eq 0 ] && pass "exit 0" || fail "exit code $RC"
  grep -q "Referenced: ${WT} (task record fm-live-task" "$OUT" && pass "reported as Referenced by task record" || fail "task reference not reported"
  [ -d "$WT" ] && pass "worktree preserved" || fail "worktree was destroyed"
  cp "$OUT" "$EV/scenario-2-task-record-preserved.log"
}

# ---------------------------------------------------------------------------
echo "=== S3: grandchild-registry walk refuses the reap (pin) ==="
{
  new_repo s3
  R="$FIX/s3/homeR"; H1="$FIX/s3/h1"; H2="$FIX/s3/h2"
  new_home "$R"; new_home "$H1"; new_home "$H2"
  mkdir -p "$FIX/s3/user-home" "$FIX/s3/homes"
  WT="$FIX/s3/wt-grand-referenced"
  git -C "$FIX/s3/repo" worktree add -q --detach "$WT" main
  printf -- '- sm-one - worker (home: %s; scope: x; projects: y; added 2024-01-01)\n' "$H1" > "$R/data/secondmates.md"
  printf -- '- sm-two - worker (home: %s; scope: x; projects: y; added 2024-01-02)\n' "$H2" > "$H1/data/secondmates.md"
  printf 'worktree=%s\n' "$WT" > "$H2/state/fm-grand-task.meta"
  OUT="$FIX/s3/out-root.log"
  env HOME="$FIX/s3/user-home" FM_HOME="$R" FM_SECONDMATE_HOMES_DIR="$FIX/s3/homes" \
    "$WRAP" --repo-dir "$FIX/s3/repo" --base-branch main > "$OUT" 2>&1
  cat "$OUT"
  grep -q "Referenced: ${WT} (task record fm-grand-task" "$OUT" && pass "run from root home refuses the reap (grandchild record found)" || fail "run from root home missed the grandchild record"
  [ -d "$WT" ] && pass "worktree preserved (root-home run)" || fail "worktree destroyed (root-home run)"
  # child-home run with a parent binding must still see the root home's records
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$R" > "$H1/.fm-secondmate-parent"
  printf 'worktree=%s\n' "$WT" > "$R/state/fm-root-task.meta"
  OUT2="$FIX/s3/out-child.log"
  env HOME="$FIX/s3/user-home" FM_HOME="$H1" FM_SECONDMATE_HOMES_DIR="$FIX/s3/homes" \
    "$WRAP" --repo-dir "$FIX/s3/repo" --base-branch main > "$OUT2" 2>&1
  cat "$OUT2"
  grep -q "Referenced: ${WT} (task record fm-root-task" "$OUT2" && pass "run from child home honors the root home's task record" || fail "child-home run missed root home record"
  [ -d "$WT" ] && pass "worktree preserved (child-home run)" || fail "worktree destroyed (child-home run)"
  cp "$OUT" "$EV/scenario-3a-grandchild-registry-refuses.log"
  cp "$OUT2" "$EV/scenario-3b-child-home-run-honors-root.log"
}

# ---------------------------------------------------------------------------
echo "=== S4: absent or unreadable FM_SECONDMATE_HOMES_DIR root is doubt (pin) ==="
{
  new_repo s4
  new_home "$FIX/s4/home"
  mkdir -p "$FIX/s4/user-home"
  WT="$FIX/s4/wt-homes-doubt"
  git -C "$FIX/s4/repo" worktree add -q --detach "$WT" main
  # (a) missing homes root
  OUT="$FIX/s4/out-missing.log"
  env HOME="$FIX/s4/user-home" FM_HOME="$FIX/s4/home" FM_SECONDMATE_HOMES_DIR="$FIX/s4/no-such-homes" \
    "$WRAP" --repo-dir "$FIX/s4/repo" --base-branch main > "$OUT" 2>&1
  cat "$OUT"
  grep -q "Referenced: ${WT} (reference scan inconclusive" "$OUT" && pass "missing homes root resolves to doubt" || fail "missing homes root not treated as doubt"
  grep -q "Safe Worktrees Reaped: 0" "$OUT" && pass "nothing reaped on missing root" || fail "something reaped on missing root"
  [ -d "$WT" ] && pass "worktree preserved (missing root)" || fail "worktree destroyed (missing root)"
  # (b) homes root that is not a directory
  printf 'not a directory\n' > "$FIX/s4/homes-file"
  OUT2="$FIX/s4/out-file.log"
  env HOME="$FIX/s4/user-home" FM_HOME="$FIX/s4/home" FM_SECONDMATE_HOMES_DIR="$FIX/s4/homes-file" \
    "$WRAP" --repo-dir "$FIX/s4/repo" --base-branch main > "$OUT2" 2>&1
  grep -q "Referenced: ${WT} (reference scan inconclusive" "$OUT2" && pass "non-directory homes root resolves to doubt" || fail "non-directory homes root not treated as doubt"
  [ -d "$WT" ] && pass "worktree preserved (non-directory root)" || fail "worktree destroyed (non-directory root)"
  # (c) unreadable homes root (chmod 000)
  mkdir -p "$FIX/s4/homes-locked"
  chmod 000 "$FIX/s4/homes-locked"
  OUT3="$FIX/s4/out-locked.log"
  env HOME="$FIX/s4/user-home" FM_HOME="$FIX/s4/home" FM_SECONDMATE_HOMES_DIR="$FIX/s4/homes-locked" \
    "$WRAP" --repo-dir "$FIX/s4/repo" --base-branch main > "$OUT3" 2>&1
  chmod 755 "$FIX/s4/homes-locked"
  grep -q "Referenced: ${WT} (reference scan inconclusive" "$OUT3" && pass "chmod-000 homes root resolves to doubt" || fail "chmod-000 homes root not treated as doubt"
  [ -d "$WT" ] && pass "worktree preserved (unreadable root)" || fail "worktree destroyed (unreadable root)"
  # (d) positive control: a homes-dir home's task record is honored
  mkdir -p "$FIX/s4/homes/domain-one/state"
  printf 'worktree=%s\n' "$WT" > "$FIX/s4/homes/domain-one/state/fm-homes-task.meta"
  OUT4="$FIX/s4/out-positive.log"
  env HOME="$FIX/s4/user-home" FM_HOME="$FIX/s4/home" FM_SECONDMATE_HOMES_DIR="$FIX/s4/homes" \
    "$WRAP" --repo-dir "$FIX/s4/repo" --base-branch main > "$OUT4" 2>&1
  grep -q "Referenced: ${WT} (task record fm-homes-task" "$OUT4" && pass "homes-dir task record honored" || fail "homes-dir task record missed"
  cat "$OUT3" > "$EV/scenario-4a-homes-root-unreadable-doubt.log"
  cat "$OUT" > "$EV/scenario-4b-homes-root-missing-doubt.log"
  cp "$OUT4" "$EV/scenario-4c-homes-dir-task-record.log"
}

# ---------------------------------------------------------------------------
echo "=== S5: TREEHOUSE_ROOT lease preserves; unprovable pool state is doubt (pin) ==="
{
  new_repo s5
  new_home "$FIX/s5/home"
  mkdir -p "$FIX/s5/user-home" "$FIX/s5/homes"
  TH="$FIX/s5/treehouse"
  mkdir -p "$TH/pool-a/slot-1" "$TH/pool-b"
  WT="$FIX/s5/treehouse/pool-a/slot-1/wt-leased"
  git -C "$FIX/s5/repo" worktree add -q --detach "$WT" main
  python3 - "$WT" "$TH/pool-a/treehouse-state.json" <<'EOF'
import json, sys
path, state = sys.argv[1], sys.argv[2]
json.dump({"version": 1, "worktrees": [{"name": "1", "path": path, "leased": True,
          "lease_id": "abc123", "lease_holder": "live-lease-holder"}]}, open(state, "w"))
EOF
  OUT="$FIX/s5/out-lease.log"
  env HOME="$FIX/s5/user-home" TREEHOUSE_ROOT="$TH" FM_HOME="$FIX/s5/home" FM_SECONDMATE_HOMES_DIR="$FIX/s5/homes" \
    "$WRAP" --repo-dir "$FIX/s5/repo" --base-branch main > "$OUT" 2>&1
  cat "$OUT"
  grep -q "Referenced: ${WT} (treehouse lease held by live-lease-holder)" "$OUT" && pass "TREEHOUSE_ROOT durable lease preserves worktree" || fail "lease not honored"
  [ -d "$WT" ] && pass "leased worktree preserved" || fail "leased worktree destroyed"
  # unprovable pool state (state file is a directory) is doubt and keeps everything
  new_repo s5b
  new_home "$FIX/s5b/home"
  mkdir -p "$FIX/s5b/user-home" "$FIX/s5b/homes" "$TH/pool-b/slot-1"
  mkdir -p "$TH/pool-b/treehouse-state.json"
  WT2="$FIX/s5b/wt-pool-doubt"
  git -C "$FIX/s5b/repo" worktree add -q --detach "$WT2" main
  OUT2="$FIX/s5/out-pooldoubt.log"
  env HOME="$FIX/s5b/user-home" TREEHOUSE_ROOT="$TH" FM_HOME="$FIX/s5b/home" FM_SECONDMATE_HOMES_DIR="$FIX/s5b/homes" \
    "$WRAP" --repo-dir "$FIX/s5b/repo" --base-branch main > "$OUT2" 2>&1
  cat "$OUT2"
  grep -q "Referenced: ${WT2} (reference scan inconclusive" "$OUT2" && pass "unprovable pool state resolves to doubt" || fail "unprovable pool state not treated as doubt"
  grep -q "treehouse pool state ${TH}/pool-b/treehouse-state.json" "$OUT2" && pass "doubt names the unprovable pool state file" || fail "doubt source not attributed"
  [ -d "$WT2" ] && pass "worktree preserved (pool state doubt)" || fail "worktree destroyed (pool state doubt)"
  # corrupt (non-JSON) pool state is also doubt, in its own pool root
  new_repo s5c
  new_home "$FIX/s5c/home"
  TH5C="$FIX/s5c/treehouse"
  mkdir -p "$FIX/s5c/user-home" "$FIX/s5c/homes" "$TH5C/pool-c"
  printf 'not json\n' > "$TH5C/pool-c/treehouse-state.json"
  WT3="$FIX/s5c/wt-corrupt-lease"
  git -C "$FIX/s5c/repo" worktree add -q --detach "$WT3" main
  OUT3="$FIX/s5/out-corruptpool.log"
  env HOME="$FIX/s5c/user-home" TREEHOUSE_ROOT="$TH5C" FM_HOME="$FIX/s5c/home" FM_SECONDMATE_HOMES_DIR="$FIX/s5c/homes" \
    "$WRAP" --repo-dir "$FIX/s5c/repo" --base-branch main > "$OUT3" 2>&1
  grep -q "Referenced: ${WT3} (reference scan inconclusive" "$OUT3" && pass "corrupt pool state resolves to doubt" || fail "corrupt pool state not treated as doubt"
  grep -q "treehouse pool state ${TH5C}/pool-c/treehouse-state.json" "$OUT3" && pass "doubt names the corrupt pool state file" || fail "doubt source not attributed"
  cp "$OUT" "$EV/scenario-5a-treehouse-lease-preserved.log"
  cp "$OUT2" "$EV/scenario-5b-pool-state-doubt.log"
  cp "$OUT3" "$EV/scenario-5c-corrupt-pool-state-doubt.log"
}

# ---------------------------------------------------------------------------
echo "=== S6: real /proc: live process and open fd preserve; probe doubt refuses ==="
{
  new_repo s6
  new_home "$FIX/s6/home"
  mkdir -p "$FIX/s6/user-home" "$FIX/s6/homes"
  WT="$FIX/s6/wt-live-process"
  git -C "$FIX/s6/repo" worktree add -q --detach "$WT" main
  mkdir -p "$WT/sub"
  ( cd "$WT/sub" && exec sleep 300 ) &
  SPID=$!
  WAITED=0
  while [ "$(readlink "/proc/$SPID/cwd" 2>/dev/null)" != "$WT/sub" ] && [ "$WAITED" -lt 20 ]; do
    WAITED=$((WAITED + 1)); sleep 0.25
  done
  note "sleep pid $SPID cwd = $(readlink "/proc/$SPID/cwd")"
  OUT="$FIX/s6/out-proc.log"
  env HOME="$FIX/s6/user-home" FM_HOME="$FIX/s6/home" FM_SECONDMATE_HOMES_DIR="$FIX/s6/homes" \
    "$WRAP" --repo-dir "$FIX/s6/repo" --base-branch main > "$OUT" 2>&1
  cat "$OUT"
  grep -q "Referenced: ${WT} (running process(es) ${SPID}" "$OUT" && pass "real /proc: live process inside preserves worktree" || fail "live process not detected"
  [ -d "$WT" ] && pass "worktree preserved (live process)" || fail "worktree destroyed (live process)"
  kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
  # open fd inside the worktree (append handle on a tracked file, no content
  # change so the tree stays clean), cwd outside it
  ( cd "$FIX/s6" && exec 3>>"$WT/README.md" && exec sleep 300 ) &
  FPID=$!
  WAITED=0
  while [ ! -e "/proc/$FPID/fd/3" ] && [ "$WAITED" -lt 20 ]; do
    WAITED=$((WAITED + 1)); sleep 0.25
  done
  note "sleep pid $FPID fd3 = $(readlink "/proc/$FPID/fd/3" 2>/dev/null), cwd = $(readlink "/proc/$FPID/cwd" 2>/dev/null)"
  OUT2="$FIX/s6/out-fd.log"
  env HOME="$FIX/s6/user-home" FM_HOME="$FIX/s6/home" FM_SECONDMATE_HOMES_DIR="$FIX/s6/homes" \
    "$WRAP" --repo-dir "$FIX/s6/repo" --base-branch main > "$OUT2" 2>&1
  cat "$OUT2"
  grep -q "Referenced: ${WT} (running process(es) ${FPID}" "$OUT2" && pass "real /proc: open fd inside preserves worktree" || fail "open fd not detected"
  [ -d "$WT" ] && pass "worktree preserved (open fd)" || fail "worktree destroyed (open fd)"
  kill "$FPID" 2>/dev/null; wait "$FPID" 2>/dev/null
  # worktree must still be clean so the next runs reach the probe
  test -z "$(git -C "$WT" status --porcelain)" && pass "worktree still clean after fd hold" || fail "worktree dirtied by the fd fixture"
  # inconclusive process probe on REAL /proc (foreign-owned pids unreadable)
  # refuses every reap
  OUT3="$FIX/s6/out-realproc-doubt.log"
  env HOME="$FIX/s6/user-home" FM_HOME="$FIX/s6/home" FM_SECONDMATE_HOMES_DIR="$FIX/s6/homes" \
    "$WRAP" --repo-dir "$FIX/s6/repo" --base-branch main > "$OUT3" 2>&1
  cat "$OUT3"
  grep -q "Referenced: ${WT} (process probe inconclusive" "$OUT3" && pass "real /proc probe doubt refuses the reap" || fail "probe doubt did not refuse"
  grep -q "Safe Worktrees Reaped: 0" "$OUT3" && pass "nothing reaped when probe cannot answer" || fail "reaped despite probe doubt"
  [ -d "$WT" ] && pass "worktree preserved (probe doubt)" || fail "worktree destroyed (probe doubt)"
  # no process table at all refuses every reap
  OUT4="$FIX/s6/out-noproc.log"
  env HOME="$FIX/s6/user-home" FM_HOME="$FIX/s6/home" FM_SECONDMATE_HOMES_DIR="$FIX/s6/homes" \
    FM_PROC_ROOT_OVERRIDE="$FIX/s6/proc-absent" \
    "$WRAP" --repo-dir "$FIX/s6/repo" --base-branch main > "$OUT4" 2>&1
  grep -q "Referenced: ${WT} (process probe inconclusive" "$OUT4" && pass "absent process table refuses the reap" || fail "absent process table did not refuse"
  [ -d "$WT" ] && pass "worktree preserved (absent process table)" || fail "worktree destroyed (absent process table)"
  cp "$OUT" "$EV/scenario-6a-real-proc-live-process.log"
  cp "$OUT2" "$EV/scenario-6b-real-proc-open-fd.log"
  cp "$OUT3" "$EV/scenario-6c-real-proc-probe-doubt-refuses.log"
  cp "$OUT4" "$EV/scenario-6d-absent-proc-table-refuses.log"
}

# ---------------------------------------------------------------------------
echo "=== S7: corrupt task meta (embedded NUL) resolves to doubt, no crash (review-7 pin) ==="
{
  new_repo s7
  new_home "$FIX/s7/home"
  mkdir -p "$FIX/s7/user-home" "$FIX/s7/homes"
  WT="$FIX/s7/wt-corrupt-meta"
  git -C "$FIX/s7/repo" worktree add -q --detach "$WT" main
  python3 - "$WT" "$FIX/s7/home/state/fm-corrupt-task.meta" <<'EOF'
import sys
path, meta = sys.argv[1], sys.argv[2]
open(meta, "wb").write(b"worktree=" + path.encode() + b"\x00\n")
EOF
  OUT="$FIX/s7/out.log"
  env HOME="$FIX/s7/user-home" FM_HOME="$FIX/s7/home" FM_SECONDMATE_HOMES_DIR="$FIX/s7/homes" \
    "$WRAP" --repo-dir "$FIX/s7/repo" --base-branch main > "$OUT" 2>&1
  RC=$?
  cat "$OUT"
  [ $RC -eq 0 ] && pass "exit 0 (no crash)" || fail "engine crashed: exit code $RC"
  grep -q "Traceback" "$OUT" && fail "python traceback in output" || pass "no traceback in output"
  grep -q "Referenced: ${WT} (reference scan inconclusive" "$OUT" && pass "corrupt meta resolves to doubt" || fail "corrupt meta not treated as doubt"
  [ -d "$WT" ] && pass "worktree preserved (corrupt meta)" || fail "worktree destroyed (corrupt meta)"
  # regression: the engine before the fix crashes on the same input
  PRE="$FIX/s7/pre-fix-engine.py"
  git -C "$RUN" show 849969293d773ec05c41dec024aad6e2a2fd9d1f^:bin/fm-jev-worktree-reaper.py > "$PRE"
  OUT_PRE="$FIX/s7/out-prefix.log"
  env HOME="$FIX/s7/user-home" FM_HOME="$FIX/s7/home" FM_SECONDMATE_HOMES_DIR="$FIX/s7/homes" \
    python3 "$PRE" --repo-dir "$FIX/s7/repo" --base-branch main > "$OUT_PRE" 2>&1
  PRE_RC=$?
  note "pre-fix engine exit code: $PRE_RC"
  tail -n 6 "$OUT_PRE"
  if [ $PRE_RC -ne 0 ] && grep -q "ValueError" "$OUT_PRE"; then
    pass "reproduced the pre-fix crash (ValueError traceback) on the same meta"
  else
    fail "pre-fix engine did not crash as reported (exit $PRE_RC)"
  fi
  [ -d "$WT" ] && pass "worktree intact after pre-fix crash (fail-closed)" || fail "worktree lost during pre-fix crash"
  cp "$OUT" "$EV/scenario-7a-corrupt-meta-doubt.log"
  cp "$OUT_PRE" "$EV/scenario-7b-prefix-crash-regression.log"
}

# ---------------------------------------------------------------------------
echo "=== S8: run summary shows the per-host inconclusive-keeps count (pin) ==="
{
  new_repo s8
  new_home "$FIX/s8/home"
  mkdir -p "$FIX/s8/user-home" "$FIX/s8/homes"
  new_proc_clean "$FIX/s8/proc-clean"
  WTA="$FIX/s8/wt-task-referenced"
  WTC="$FIX/s8/wt-reapable"
  git -C "$FIX/s8/repo" worktree add -q --detach "$WTA" main
  git -C "$FIX/s8/repo" worktree add -q --detach "$WTC" main
  printf 'worktree=%s\n' "$WTA" > "$FIX/s8/home/state/fm-mixed-task.meta"
  OUT="$FIX/s8/out.json"
  env HOME="$FIX/s8/user-home" FM_HOME="$FIX/s8/home" FM_SECONDMATE_HOMES_DIR="$FIX/s8/homes" \
    FM_PROC_ROOT_OVERRIDE="$FIX/s8/proc-clean" \
    "$WRAP" --repo-dir "$FIX/s8/repo" --base-branch main --json > "$OUT" 2>&1
  python3 - "$OUT" "$WTA" "$WTC" <<'EOF'
import json, sys
out, wta, wtc = sys.argv[1:4]
d = json.load(open(out))
assert d["referenced_preserved"] == 1, d
assert d["inconclusive_preserved"] == 0, d
assert len(d["reaped_worktrees"]) == 1 and d["reaped_worktrees"][0]["path"] == wtc, d
assert {r["path"] for r in d["referenced_worktrees"]} == {wta}, d
print("JSON counts ok: referenced=1 inconclusive=0 reaped=1")
EOF
  [ $? -eq 0 ] && pass "JSON telemetry counts match the per-worktree dispositions" || fail "JSON counts wrong"
  [ -d "$WTA" ] && [ ! -d "$WTC" ] && pass "referenced kept, unreferenced reaped" || fail "wrong worktree disposition"
  # visible per-host inconclusive-keeps count: run against real /proc where the
  # probe doubts; the summary count must equal the visible detail lines
  new_repo s8b
  new_home "$FIX/s8b/home"
  mkdir -p "$FIX/s8b/user-home" "$FIX/s8b/homes"
  WTB1="$FIX/s8b/wt-task-referenced"
  WTB2="$FIX/s8b/wt-inconclusive-1"
  WTB3="$FIX/s8b/wt-inconclusive-2"
  for wt in "$WTB1" "$WTB2" "$WTB3"; do git -C "$FIX/s8b/repo" worktree add -q --detach "$wt" main; done
  printf 'worktree=%s\n' "$WTB1" > "$FIX/s8b/home/state/fm-mixed-task.meta"
  OUT2="$FIX/s8b/out-text.log"
  env HOME="$FIX/s8b/user-home" FM_HOME="$FIX/s8b/home" FM_SECONDMATE_HOMES_DIR="$FIX/s8b/homes" \
    "$WRAP" --repo-dir "$FIX/s8b/repo" --base-branch main > "$OUT2" 2>&1
  cat "$OUT2"
  VISIBLE=$(grep -c "process probe inconclusive" "$OUT2" || true)
  grep -q "Preserved (Inconclusive): ${VISIBLE}" "$OUT2" && [ "$VISIBLE" -eq 2 ] \
    && pass "summary shows the visible per-host inconclusive-keeps count (${VISIBLE})" || fail "summary count does not match visible inconclusive keeps (visible=$VISIBLE)"
  grep -q "Preserved (Referenced): 3" "$OUT2" && pass "all three kept worktrees counted as referenced" || fail "referenced count wrong"
  grep -q "Referenced: ${WTB1} (task record fm-mixed-task" "$OUT2" && pass "task-referenced line still attributed to its task record" || fail "task reference attribution lost"
  [ -d "$WTB1" ] && [ -d "$WTB2" ] && [ -d "$WTB3" ] && pass "every worktree preserved" || fail "a worktree was destroyed"
  cp "$OUT" "$EV/scenario-8a-mixed-json-counts.log"
  cp "$OUT2" "$EV/scenario-8b-inconclusive-count-summary.log"
}

# ---------------------------------------------------------------------------
echo "=== S9: merge-hook-shape invocation consults the wrapper-resolved FM_HOME ==="
{
  new_repo s9
  new_home "$FIX/s9/hook-home"
  mkdir -p "$FIX/s9/user-home" "$FIX/s9/homes"
  WT="$FIX/s9/wt-hook-referenced"
  git -C "$FIX/s9/repo" worktree add -q --detach "$WT" main
  printf 'worktree=%s\n' "$WT" > "$FIX/s9/hook-home/state/fm-hook-task.meta"
  # exactly the fm-pr-merge.sh hook shape: --repo-name "${PR_REPO:-}", FM_HOME
  # unset in the caller so the wrapper resolves it from FM_ROOT_OVERRIDE
  new_proc_clean "$FIX/s9/proc-clean"
  OUT="$FIX/s9/out.log"
  ( cd "$FIX/s9/repo" && env -u FM_HOME HOME="$FIX/s9/user-home" FM_ROOT_OVERRIDE="$FIX/s9/hook-home" \
      FM_SECONDMATE_HOMES_DIR="$FIX/s9/homes" FM_PROC_ROOT_OVERRIDE="$FIX/s9/proc-clean" \
      "$WRAP" --repo-name "" 2>&1 ) > "$OUT"
  RC=$?
  cat "$OUT"
  [ $RC -eq 0 ] && pass "exit 0" || fail "exit code $RC"
  grep -q "Referenced: ${WT} (task record fm-hook-task" "$OUT" && pass "hook-resolved FM_HOME task record honored" || fail "wrapper-resolved FM_HOME not consulted"
  [ -d "$WT" ] && pass "worktree preserved" || fail "worktree destroyed"
  # same invocation without the record must still be free to reap
  rm "$FIX/s9/hook-home/state/fm-hook-task.meta"
  OUT2="$FIX/s9/out-noref.log"
  ( cd "$FIX/s9/repo" && env -u FM_HOME HOME="$FIX/s9/user-home" FM_ROOT_OVERRIDE="$FIX/s9/hook-home" \
      FM_SECONDMATE_HOMES_DIR="$FIX/s9/homes" FM_PROC_ROOT_OVERRIDE="$FIX/s9/proc-clean" \
      "$WRAP" --repo-name "" 2>&1 ) > "$OUT2"
  grep -q "Reaped: ${WT} " "$OUT2" && [ ! -d "$WT" ] && pass "record removal changes the verdict (reaped)" || fail "verdict not driven by the home's records"
  cp "$OUT" "$EV/scenario-9a-hook-shape-fm-home-record.log"
  cp "$OUT2" "$EV/scenario-9b-hook-shape-no-record-reaped.log"
}

echo
echo "=== RESULT: $FAILS failed assertion(s) ==="
exit $FAILS
