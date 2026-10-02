#!/usr/bin/env bash
# Adversarial matrix for the refined tests/fm-fleet-cleanup-skill.test.sh (target
# head 869a054c) versus the previously-published version (PR head 4b75fbd7).
# Drives both tests as executables against mutated skill/index artifacts in a
# disposable git-archive copy of the tree. Exits non-zero if any expectation
# mismatches.
set -u

WT="/home/jon/.no-mistakes/worktrees/2f32188048b1/01M3XE98FC2GZYZAP5HZ09T5RY"
S="$WT/.nm-test-scratch/target"
FAILURES=0

say()  { printf '%s\n' "$*"; }
expect() { # label expected_exit actual_exit
  if [ "$2" = "$3" ]; then
    say "OK        $1 (exit=$3, expected $2)"
  else
    say "MISMATCH  $1 (exit=$3, expected $2)"
    FAILURES=$((FAILURES + 1))
  fi
}

cd "$WT" || exit 1
rm -rf "$S"
mkdir -p "$S"
git archive HEAD | tar -x -C "$S"
git show 4b75fbd721ab2a189f8764badb900f88bbb60e20:tests/fm-fleet-cleanup-skill.test.sh \
  > "$S/tests/published-fm-fleet-cleanup-skill.test.sh"

SKILL="$S/.agents/skills/fleet-cleanup/SKILL.md"
INDEX="$S/.agents/skills/agent-skill-trigger-index/SKILL.md"
cp "$SKILL" "$S/.skill.pristine"
cp "$INDEX" "$S/.index.pristine"

NEW="$S/tests/fm-fleet-cleanup-skill.test.sh"
OLD="$S/tests/published-fm-fleet-cleanup-skill.test.sh"

restore() { cp "$S/.skill.pristine" "$SKILL"; cp "$S/.index.pristine" "$INDEX"; }

run_both() { # label expected_new expected_old
  local label="$1" exp_new="$2" exp_old="$3" out rc
  out=$(cd "$S" && bash tests/fm-fleet-cleanup-skill.test.sh 2>&1); rc=$?
  say "--- refined test on: $label"
  printf '%s\n' "$out" | sed 's/^/    /'
  expect "$label :: refined test" "$exp_new" "$rc"
  out=$(cd "$S" && bash tests/published-fm-fleet-cleanup-skill.test.sh 2>&1); rc=$?
  say "--- published(4b75fbd7) test on: $label"
  printf '%s\n' "$out" | sed 's/^/    /'
  expect "$label :: published test" "$exp_old" "$rc"
}

say "================ baseline (unmutated artifact) ================"
run_both "baseline" 0 0

say "================ A1: duplicate metadata.internal (false last) ================"
python3 - "$SKILL" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "metadata:\n  internal: true\n"
assert old in s, "anchor not found"
s = s.replace(old, "metadata:\n  internal: true\n  internal: false\n", 1)
open(p, "w").write(s)
PY
run_both "duplicate metadata.internal=false" 1 0
restore

say "================ A2: duplicate user-invocable (true last) ================"
python3 - "$SKILL" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "user-invocable: false\n"
assert old in s, "anchor not found"
s = s.replace(old, "user-invocable: false\nuser-invocable: true\n", 1)
open(p, "w").write(s)
PY
run_both "duplicate user-invocable=true" 1 0
restore

say "================ B2: semantically-equivalent trigger bullet reflow ================"
python3 - "$INDEX" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().split("\n")
hit = False
for i, ln in enumerate(lines):
    if ln.startswith("- `fleet-cleanup` - load "):
        lines[i] = "- `fleet-cleanup` -\n  " + ln[len("- `fleet-cleanup` - "):]
        hit = True
        break
assert hit, "fleet-cleanup bullet not found"
open(p, "w").write("\n".join(lines))
PY
run_both "trigger bullet reflowed onto continuation line" 0 1
restore

say "================ C: fleet-cleanup trigger bullet removed ================"
python3 - "$INDEX" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().split("\n")
out = [ln for ln in lines if not ln.startswith("- `fleet-cleanup` ")]
assert len(out) < len(lines), "fleet-cleanup bullet not found"
open(p, "w").write("\n".join(out))
PY
run_both "fleet-cleanup trigger entry removed" 1 1
restore

say "================ post-matrix: restored artifact still validates ================"
run_both "restored artifact" 0 0

say ""
if [ "$FAILURES" -eq 0 ]; then
  say "MATRIX RESULT: all expectations matched"
else
  say "MATRIX RESULT: $FAILURES expectation(s) mismatched"
fi
exit "$FAILURES"
