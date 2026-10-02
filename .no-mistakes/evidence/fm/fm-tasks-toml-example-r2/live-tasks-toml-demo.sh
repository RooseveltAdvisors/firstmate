#!/usr/bin/env bash
# Live driver for the per-home .tasks.toml change (fm/fm-tasks-toml-example-r2).
# Runs the real product: bin/fm-bootstrap.sh session start, bin/fm-ff-lib.sh
# ff_target advances, the real tasks-axi CLI, real git, and bin/fm-test-run.sh
# changed-path selection - all against disposable fixtures under the test tmp root.
set -u

WT=/home/jon/.no-mistakes/worktrees/2f32188048b1/01M3XK0SGH8WM3HS11AWRH9AEQ
EV=/home/jon/.no-mistakes/evidence/01M3XK0SGH8WM3HS11AWRH9AEQ
cd "$WT" || exit 1
ROOT=$WT
TARGET_SHA=cc11149a8c832bb7dc5b78f634095ff5cd2a27fb
BASE_SHA=8690c4117a298ee870f0f72f571c72b846b4c5fb

FAILS=0
ok()  { printf 'ok - %s\n' "$*"; }
bad() { printf 'FAIL - %s\n' "$*"; FAILS=$((FAILS + 1)); }

# Reuse the shipped suite's fixture builders (fake toolchain, routine bootstrap
# home, run_bootstrap_home) without running its test invocations.
HELPERS="$WT/tests/.demo-helpers.sh"
sed '/^test_[a-z0-9_]*$/d' tests/fm-bootstrap.test.sh > "$HELPERS" || exit 1
# shellcheck disable=SC1090
. "$HELPERS"
set +u
. "$ROOT/bin/fm-ff-lib.sh"   # ff_target, dirty_status, carry helpers
set -u

fm_git_identity

run_ff() {  # <dir> -> prints ff output then FF_STATUS
  (
    set +u
    ff_target "$1" "home" origin yes no
    printf 'FF_STATUS=%s\n' "$FF_STATUS"
  )
}

say_section() { printf '\n===== %s =====\n' "$*"; }

# ---------------------------------------------------------------- demo A -----
# Fresh home: session start materializes .tasks.toml from the tracked example,
# the real tasks-axi CLI then addresses data/backlog.md + archive from it,
# while a home WITHOUT the config falls back to tasks-axi's built-in default
# (./backlog.md). Re-running bootstrap leaves a customized copy untouched.
say_section "A: fresh home seeds config; tasks-axi honors it; custom copy untouched"
caseA="$TMP_ROOT/demoA"
fixture=$(make_routine_bootstrap_fixture "$caseA")
rootA=${fixture%%|*}; fixture=${fixture#*|}
homeA=${fixture%%|*}
fakebinA=${fixture#*|}

outA=$(run_bootstrap_home "$fakebinA" "$homeA" "$rootA")
if [ -z "$outA" ]; then ok "bootstrap session start is silent on a fresh home"
else bad "bootstrap printed: $outA"; fi
if cmp -s "$homeA/.tasks.toml" "$ROOT/.tasks.toml.example"; then
  ok "bootstrap materialized .tasks.toml byte-identical to .tasks.toml.example"
else
  bad "materialized .tasks.toml differs from the tracked example"
fi

mkdir -p "$homeA/data"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$homeA/data/backlog.md"
for i in 1 2 3 4 5 6 7 8 9 10 11; do
  (cd "$homeA" && tasks-axi add "fm-live-$i" "row $i" >/dev/null 2>&1) || bad "tasks-axi add $i failed"
  (cd "$homeA" && tasks-axi start "fm-live-$i" >/dev/null 2>&1) || bad "tasks-axi start $i failed"
  (cd "$homeA" && tasks-axi "done" "fm-live-$i" >/dev/null 2>&1) || bad "tasks-axi done $i failed"
done
if [ -f "$homeA/data/done-archive.md" ]; then
  ok "tasks-axi honored the seeded config: archive written to data/done-archive.md"
else
  bad "tasks-axi did not write data/done-archive.md from the seeded config"
fi
if [ ! -e "$homeA/backlog.md" ]; then
  ok "tasks-axi addressed data/backlog.md, not a root-level backlog.md"
else
  bad "tasks-axi created $homeA/backlog.md despite the seeded config"
fi
ok "archive head: $(head -3 "$homeA/data/done-archive.md" 2>/dev/null | tr '\n' ' ')"

ctrl="$TMP_ROOT/demoA/no-config-home"
mkdir -p "$ctrl"
(cd "$ctrl" && tasks-axi add fm-ctrl-1 "row" >/dev/null 2>&1)
if [ -f "$ctrl/backlog.md" ]; then
  ok "control: a home with NO config falls back to tasks-axi default ./backlog.md (the degradation seeding prevents)"
else
  bad "control: tasks-axi did not fall back to its default layout"
fi

printf 'backend = "markdown"\n\n[markdown]\npath = "data/other.md"\ndone_keep = 3\n' > "$homeA/.tasks.toml"
cp "$homeA/.tasks.toml" "$caseA/custom-saved.toml"
outA2=$(run_bootstrap_home "$fakebinA" "$homeA" "$rootA")
if cmp -s "$homeA/.tasks.toml" "$caseA/custom-saved.toml"; then
  ok "second session start leaves a customized .tasks.toml byte-for-byte untouched"
else
  bad "second session start rewrote the customized copy (out: $outA2)"
fi
case "$outA2" in
  *TASKS_CONFIG*) bad "second session start reported TASKS_CONFIG: $outA2" ;;
  *) ok "second session start reports no TASKS_CONFIG diagnostic" ;;
esac
[ -n "$outA2" ] && echo "note (unrelated to .tasks.toml): second run also printed: $(printf '%s' "$outA2" | tr '\n' ';')"

# ---------------------------------------------------------------- demo B -----
# A home that IS a git checkout of this branch (the real primary-home layout):
# bootstrap seeds .tasks.toml, git ignores it (clean tree), an ff advance via
# ff_target still works, real dirt still refuses.
say_section "B: gitignored live file keeps the checkout clean and the advance eligible"
caseB="$TMP_ROOT/demoB"
homeB="$caseB/home"
upB="$caseB/upstream"
mkdir -p "$homeB" "$homeB/state" "$homeB/config"
git init -q -b main "$homeB"
git -C "$WT" archive "$TARGET_SHA" | tar -x -C "$homeB"
git -C "$homeB" add -A
git -C "$homeB" commit -qm "target tree"
printf '%s\n' codex > "$homeB/config/crew-harness"
printf '%s\n' '{"rules":[{"when":"normal work","use":{"harness":"codex"}}],"default":{"harness":"claude","effort":"low"}}' \
  > "$homeB/config/crew-dispatch.json"

outB=$(run_bootstrap_home "$fakebinA" "$homeB" "$homeB" 2>&1)
case "$outB" in
  *TASKS_CONFIG*) bad "bootstrap reported TASKS_CONFIG in the checkout home: $outB" ;;
  *) ok "bootstrap seeded the checkout home without diagnostics" ;;
esac
if cmp -s "$homeB/.tasks.toml" "$ROOT/.tasks.toml.example"; then
  ok "checkout home got .tasks.toml from the tracked example"
else
  bad "checkout home config differs from the example"
fi
porc=$(git -C "$homeB" status --porcelain)
if [ -z "$porc" ]; then
  ok "git status --porcelain is empty after seeding (live file does not dirty the home)"
else
  bad "seeding dirtied the checkout: $porc"
fi
ign=$(git -C "$homeB" check-ignore -v .tasks.toml)
case "$ign" in
  .gitignore:*:.tasks.toml*) ok "git ignores the live file: $ign" ;;
  *) bad "check-ignore did not attribute .tasks.toml to .gitignore: '$ign'" ;;
esac
ignored=$(git -C "$homeB" status --porcelain --ignored=matching | grep -c '^!! \.tasks\.toml$' || true)
[ "$ignored" -eq 1 ] && ok "git status --ignored lists .tasks.toml as ignored" \
  || bad "git status --ignored does not list .tasks.toml"
tracked=$(git -C "$homeB" ls-files .tasks.toml)
[ -z "$tracked" ] && ok "git ls-files shows .tasks.toml is not tracked" \
  || bad ".tasks.toml is tracked: $tracked"
ex=$(git -C "$homeB" ls-files .tasks.toml.example)
[ "$ex" = ".tasks.toml.example" ] && ok "git ls-files shows .tasks.toml.example is tracked" \
  || bad ".tasks.toml.example not tracked: '$ex'"

# Advance the checkout: upstream gets a new commit, ff_target fast-forwards it.
git clone -q "$homeB" "$upB"
printf '\n<!-- advance marker -->\n' >> "$upB/CONTRIBUTING.md"
git -C "$upB" add CONTRIBUTING.md
git -C "$upB" commit -qm "upstream advance"
git -C "$homeB" remote add origin "$upB"
cp "$homeB/.tasks.toml" "$caseB/pre-advance-config.toml"
ff1=$(run_ff "$homeB")
printf '%s\n' "$ff1"
echo "$ff1" | grep -q '^FF_STATUS=updated$' && ok "ff_target fast-forwarded the home (FF_STATUS=updated)" \
  || bad "ff_target did not advance: $ff1"
cmp -s "$homeB/.tasks.toml" "$caseB/pre-advance-config.toml" \
  && ok ".tasks.toml survived the advance byte-for-byte" \
  || bad ".tasks.toml changed across the advance"
[ -z "$(git -C "$homeB" status --porcelain)" ] \
  && ok "home still clean after the advance" \
  || bad "home dirty after the advance: $(git -C "$homeB" status --porcelain)"

# Adversarial: unrelated dirt must still refuse the advance (ignore ≠ blanket).
printf '\n# dirt\n' >> "$homeB/AGENTS.md"
ff2=$(run_ff "$homeB")
printf '%s\n' "$ff2"
echo "$ff2" | grep -q 'skipped: dirty working tree' \
  && ok "adversarial: real dirt still refuses the advance (skip is not masked by the ignore)" \
  || bad "dirty guard did not fire on real dirt: $ff2"
git -C "$homeB" checkout -- AGENTS.md
ff3=$(run_ff "$homeB")
echo "$ff3" | grep -q '^FF_STATUS=current$' \
  && ok "clean home reads 'already current' after the advance" \
  || bad "expected already-current after dirt cleared: $ff3"

# ---------------------------------------------------------------- demo C -----
# The core user story: a home running on the TRACKED .tasks.toml (base tree)
# fast-forwards across the commit that untracks it - the file must be carried
# across and reported; a customized tracked copy must refuse with a named reason.
say_section "C: the untracking advance carries the live file; a modified tracked copy refuses"
caseC="$TMP_ROOT/demoC"
homeC="$caseC/home"
upC="$caseC/upstream"
mkdir -p "$homeC"
git init -q -b main "$homeC"
git -C "$WT" archive "$BASE_SHA" | tar -x -C "$homeC"
git -C "$homeC" add -A
git -C "$homeC" commit -qm "base tree (tracked .tasks.toml)"
cp "$homeC/.tasks.toml" "$caseC/base-config.toml"
git clone -q "$homeC" "$upC"
git -C "$upC" mv .tasks.toml .tasks.toml.example
printf '.tasks.toml\n' >> "$upC/.gitignore"
git -C "$upC" add -A
git -C "$upC" commit -qm "untrack .tasks.toml: example + gitignore"
git -C "$homeC" remote add origin "$upC"

ffC=$(run_ff "$homeC")
printf '%s\n' "$ffC"
echo "$ffC" | grep -q '^FF_STATUS=updated$' && ok "the untracking advance fast-forwarded (FF_STATUS=updated)" \
  || bad "advance failed: $ffC"
echo "$ffC" | grep -q '^TASKS_CONFIG: restored ' && ok "advance reported the carry: $(echo "$ffC" | grep '^TASKS_CONFIG:')" \
  || bad "advance did not report TASKS_CONFIG restore: $ffC"
[ -f "$homeC/.tasks.toml" ] && cmp -s "$homeC/.tasks.toml" "$caseC/base-config.toml" \
  && ok "live .tasks.toml carried byte-for-byte across the untracking advance" \
  || bad "live .tasks.toml was lost or altered across the advance"
[ -f "$homeC/.tasks.toml.example" ] && ok "home now also holds the tracked .tasks.toml.example" \
  || bad ".tasks.toml.example missing after advance"
[ -z "$(git -C "$homeC" status --porcelain)" ] \
  && ok "restored file is ignored: home clean after carry" \
  || bad "home dirty after carry: $(git -C "$homeC" status --porcelain)"

# Adversarial: modified-and-tracked copy must refuse with an actionable reason.
homeC2="$caseC/home2"
mkdir -p "$homeC2"
git init -q -b main "$homeC2"
git -C "$WT" archive "$BASE_SHA" | tar -x -C "$homeC2"
git -C "$homeC2" add -A
git -C "$homeC2" commit -qm "base tree (tracked .tasks.toml)"
printf 'done_keep = 99\n' >> "$homeC2/.tasks.toml"
git -C "$homeC2" remote add origin "$upC"
head_before=$(git -C "$homeC2" rev-parse HEAD)
ffC2=$(run_ff "$homeC2")
printf '%s\n' "$ffC2"
echo "$ffC2" | grep -q '.tasks.toml is modified and still tracked here' \
  && ok "adversarial: modified tracked copy refuses with a reason that names the file and the way out" \
  || bad "no actionable named reason: $ffC2"
grep -q 'done_keep = 99' "$homeC2/.tasks.toml" && ok "customization preserved (never stashed/discarded)" \
  || bad "customization was discarded"
[ "$(git -C "$homeC2" rev-parse HEAD)" = "$head_before" ] && ok "advance stayed refused (HEAD unchanged)" \
  || bad "refused advance still moved HEAD"

# ---------------------------------------------------------------- demo D -----
# bin/fm-test-run.sh changed-path selection: .tasks.toml.example selects the
# session-bootstrap coverage that runs it; a bin/fm-ff-lib.sh change selects the
# update and secondmate-sync suites that actually exercise it.
say_section "D: changed-path test selection through the real runner"
caseD="$TMP_ROOT/demoD"
repoD="$caseD/repo"
mkdir -p "$repoD/bin" "$repoD/tests"
cp "$ROOT/bin/fm-test-run.sh" "$repoD/bin/"
cp "$ROOT/tests/git-config-helpers.sh" "$repoD/tests/"
chmod +x "$repoD/bin/fm-test-run.sh"
for t in fm-bootstrap fm-session-start fm-brief fm-update fm-secondmate-sync; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repoD/tests/$t.test.sh"
  chmod +x "$repoD/tests/$t.test.sh"
done
: > "$repoD/bin/fm-ff-lib.sh"
git -C "$repoD" init -q
git -C "$repoD" add .
git -C "$repoD" commit -qm baseline

cp "$ROOT/.tasks.toml.example" "$repoD/.tasks.toml.example"
git -C "$repoD" add .tasks.toml.example
sel1=$(cd "$repoD" && bin/fm-test-run.sh --list --changed --base HEAD 2>&1)
printf '%s\n' "$sel1"
echo "$sel1" | grep -qx 'tests/fm-bootstrap.test.sh' \
  && ok "selecting .tasks.toml.example runs the session-bootstrap suite (fm-bootstrap.test.sh)" \
  || bad ".tasks.toml.example did not select fm-bootstrap.test.sh: $sel1"
echo "$sel1" | grep -qx 'tests/fm-brief.test.sh' \
  && ok ".tasks.toml.example also runs its contract family (fm-brief.test.sh)" \
  || bad "contract family not selected: $sel1"
if echo "$sel1" | grep -qx 'tests/fm-secondmate-sync.test.sh'; then
  bad ".tasks.toml.example unexpectedly selects the secondmate suite"
else
  ok ".tasks.toml.example does not pull in unrelated secondmate coverage"
fi
git -C "$repoD" commit -qm "add example"
printf '\n# touch\n' >> "$repoD/bin/fm-ff-lib.sh"
sel2=$(cd "$repoD" && bin/fm-test-run.sh --list --changed --base HEAD 2>&1)
printf '%s\n' "$sel2"
echo "$sel2" | grep -qx 'tests/fm-update.test.sh' \
  && ok "bin/fm-ff-lib.sh change selects the update suite" \
  || bad "ff-lib change missed fm-update.test.sh: $sel2"
echo "$sel2" | grep -qx 'tests/fm-secondmate-sync.test.sh' \
  && ok "bin/fm-ff-lib.sh change selects the secondmate-sync suite" \
  || bad "ff-lib change missed fm-secondmate-sync.test.sh: $sel2"

# ---------------------------------------------------------------- demo E -----
say_section "E: mergeability against live upstream main"
remote_main=$(git ls-remote origin refs/heads/main | awk '{print $1}')
ok "git ls-remote origin refs/heads/main = $remote_main"
[ "$remote_main" = "$(git rev-parse origin/main)" ] \
  && ok "local origin/main ref matches the live upstream tip" \
  || bad "local origin/main ($remote_main) differs from live tip"
git merge-base --is-ancestor "$BASE_SHA" HEAD \
  && ok "branch contains the merge base (base commit is an ancestor of the target)" \
  || bad "base commit is not an ancestor"
git merge-base --is-ancestor origin/main HEAD \
  && ok "current origin/main is already merged into the branch" \
  || echo "note: upstream advanced past the merge; conflict-checking the current tip"
mt=$(git merge-tree --write-tree origin/main HEAD 2>&1); mtrc=$?
if [ "$mtrc" -eq 0 ]; then
  ok "git merge-tree origin/main HEAD merges cleanly (tree $mt, no conflicts)"
else
  bad "merge-tree reports conflicts: $mt"
fi
parents=$(git rev-list --parents -n 1 2ba3da64ede6257ffc06d11c0a9fe620f79aafef)
case "$parents" in
  *" $BASE_SHA") ok "the PR carries an explicit 'Merge origin/main' commit (2ba3da64)" ;;
  *) bad "merge commit parents unexpected: $parents" ;;
esac

printf '\nSUMMARY: %s failure(s)\n' "$FAILS"
rm -f "$HELPERS"
[ "$FAILS" -eq 0 ]
