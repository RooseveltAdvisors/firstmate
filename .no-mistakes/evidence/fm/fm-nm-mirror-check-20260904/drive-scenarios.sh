#!/usr/bin/env bash
# Live scenario driver for the NO_MISTAKES_MIRROR bootstrap change
# (branch fm/fm-nm-mirror-check-20260904, head a1553be4).
#
# Every run below executes the REAL product script bin/fm-bootstrap.sh from
# the run worktree against a disposable lab home (bin/fm-lab-home.sh create)
# whose registry, clones, and firstmate checkouts are fixtures. Nothing under
# the operator's real FM_HOME/NM_HOME is read or written: NM_HOME is pinned to
# a lab directory (it is only ever used as the string prefix of remote URLs)
# except in the explicitly-labelled default-root scenarios, where only git
# config strings are compared and no file under ~/.no-mistakes is touched.
set -u

EV=/home/jon/.no-mistakes/evidence/01M3X6W5PXZ2VKJC3JQ3H748P6
WT=/home/jon/.no-mistakes/worktrees/2f32188048b1/01M3X6W5PXZ2VKJC3JQ3H748P6
LAB=$(cat "$EV/.lab-path")
ROOT_A="$LAB/nm-root-active"
ROOT_B="$LAB/nm-root-stale"
cd "$WT" || exit 1

PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

# run_boot <extra-env-assignments...> -> stdout+stderr of the real bootstrap
# FMH selects the lab home to drive (default: the drift home).
run_boot() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u NM_HOME \
    NM_HOME="$ROOT_A" FM_HOME="${FMH:-$LAB}" FM_BOOTSTRAP_NETWORK=skip "$@" \
    bin/fm-bootstrap.sh 2>&1
}

# A second lab home that is healthy in every dimension: healthy no-mistakes
# clone, never-cloned entry, and drifted clones under NON no-mistakes postures
# (which must stay silent because the check is scoped to no-mistakes posture).
mkdir -p "$LAB/healthy-home/config" "$LAB/healthy-home/data" "$LAB/healthy-home/projects"
printf '%s\n' manual > "$LAB/healthy-home/config/backlog-backend"
printf '%s\n' \
  '- well [no-mistakes] - healthy clone (added 2026-09-04)' \
  '- ghost [no-mistakes] - registered but never cloned (added 2026-09-04)' \
  '- quick [direct-PR] - drifted but out of scope (added 2026-09-04)' \
  '- vault [local-only] - drifted but out of scope (added 2026-09-04)' \
  > "$LAB/healthy-home/data/projects.md"
git init -q -b main "$LAB/healthy-home/projects/well"
git -C "$LAB/healthy-home/projects/well" remote add no-mistakes "$ROOT_A/repos/well.git"
git init -q -b main "$LAB/healthy-home/projects/quick"
git -C "$LAB/healthy-home/projects/quick" remote add no-mistakes "$ROOT_B/repos/quick.git"
git init -q -b main "$LAB/healthy-home/projects/vault"
git -C "$LAB/healthy-home/projects/vault" remote add no-mistakes "$ROOT_B/repos/vault.git"
mirror_lines() { grep '^NO_MISTAKES_MIRROR:' || true; }

# --- expected report set for the drift home -----------------------------
expected_drift_set() {
  cat <<EOF
NO_MISTAKES_MIRROR: firstmate remote=$ROOT_B/repos/fm.git expected-root=$ROOT_A (run no-mistakes init inside $LAB/fm-root-drift to point its gate at the active root)
NO_MISTAKES_MIRROR: macro remote=$ROOT_B/repos/macro.git expected-root=$ROOT_A (run no-mistakes init inside $LAB/projects/macro to point its gate at the active root)
NO_MISTAKES_MIRROR: portal remote=$ROOT_B/repos/portal.git expected-root=$ROOT_A (run no-mistakes init inside $LAB/projects/portal to point its gate at the active root)
NO_MISTAKES_MIRROR: absent remote=absent expected-root=$ROOT_A (run no-mistakes init inside $LAB/projects/absent to point its gate at the active root)
NO_MISTAKES_MIRROR: my portal remote=$ROOT_B/repos/my-portal.git expected-root=$ROOT_A (run no-mistakes init inside $LAB/projects/my portal to point its gate at the active root)
NO_MISTAKES_MIRROR: linked remote=$ROOT_B/repos/linked.git expected-root=$ROOT_A (run no-mistakes init inside $LAB/projects/linked to point its gate at the active root)
EOF
}

echo "==================================================================="
echo "S1+S2: drift reported for no-mistakes-posture clones; everything else silent"
echo "==================================================================="
out=$(run_boot FM_ROOT_OVERRIDE="$LAB/fm-root-drift" FM_BOOTSTRAP_DETECT_ONLY=1)
echo "$out"
echo "--- mirror lines ---"
actual=$(mirror_lines <<<"$out")
echo "$actual"
expected=$(expected_drift_set)
if [ "$actual" = "$expected" ]; then
  pass "exactly the 6 expected drift lines: firstmate, macro, portal, absent, 'my portal' (full spaced name), linked; silent for quick(vault?), vault, ghost, well, 'my', secret vault, nested"
else
  fail "drift report set mismatch"
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/  /'
fi
for silent in quick vault ghost well "secret vault" nested; do
  if grep -q "^NO_MISTAKES_MIRROR: $silent \|^NO_MISTAKES_MIRROR: $silent remote" <<<"$actual"; then
    fail "silently-scoped project '$silent' was reported"
  else
    pass "'$silent' stayed silent (posture gating / never-cloned / not-a-clone-root)"
  fi
done
if grep -q '^NO_MISTAKES_MIRROR: my remote' <<<"$actual"; then
  fail "'my' (healthy single-word name) was reported"
else
  pass "'my' (healthy) silent while 'my portal' (drifted) reported under its full name"
fi

echo
echo "==================================================================="
echo "S3: a fully healthy home is completely silent"
echo "==================================================================="
FMH="$LAB/healthy-home"
out=$(run_boot FM_ROOT_OVERRIDE="$LAB/fm-root-healthy" FM_BOOTSTRAP_DETECT_ONLY=1)
ml=$(mirror_lines <<<"$out")
unset FMH
if [ -z "$ml" ]; then
  pass "healthy firstmate checkout + healthy no-mistakes clone + never-cloned + out-of-scope postures printed no NO_MISTAKES_MIRROR line"
else
  fail "healthy home printed: $ml"
fi
echo "--- (full bootstrap output for the healthy home) ---"
echo "$out"

echo
echo "==================================================================="
echo "S4a: trailing-slash NM_HOME normalizes (no false drift, no '//' roots)"
echo "==================================================================="
out=$(run_boot NM_HOME="$ROOT_A///" FM_ROOT_OVERRIDE="$LAB/fm-root-drift" FM_BOOTSTRAP_DETECT_ONLY=1)
actual=$(mirror_lines <<<"$out")
if [ "$actual" = "$expected" ]; then
  pass "NM_HOME='$ROOT_A///' produced byte-identical expected-root=$ROOT_A report"
else
  fail "trailing-slash NM_HOME report mismatch"
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/  /'
fi

echo
echo "==================================================================="
echo "S4b: bare '/' NM_HOME: /repos/* stays healthy, other paths still drift"
echo "==================================================================="
git -C "$LAB/fm-root-absent" remote remove no-mistakes 2>/dev/null || true
git -C "$LAB/fm-root-absent" remote add no-mistakes /repos/fm.git
out=$(run_boot NM_HOME=/ FM_ROOT_OVERRIDE="$LAB/fm-root-absent" FM_BOOTSTRAP_DETECT_ONLY=1)
if mirror_lines <<<"$out" | grep -q '^NO_MISTAKES_MIRROR: firstmate'; then
  fail "bare / root falsely flagged a healthy /repos/* remote (double-slash prefix bug)"
else
  pass "bare / root accepted the healthy /repos/fm.git remote (no //repos prefix bug)"
fi
git -C "$LAB/fm-root-absent" remote set-url no-mistakes /elsewhere/fm.git
out=$(run_boot NM_HOME=/ FM_ROOT_OVERRIDE="$LAB/fm-root-absent" FM_BOOTSTRAP_DETECT_ONLY=1)
line=$(mirror_lines <<<"$out" | grep '^NO_MISTAKES_MIRROR: firstmate' || true)
if [ "$line" = "NO_MISTAKES_MIRROR: firstmate remote=/elsewhere/fm.git expected-root=/ (run no-mistakes init inside $LAB/fm-root-absent to point its gate at the active root)" ]; then
  pass "bare / root still reports a remote outside /repos/ with expected-root=/"
else
  fail "bare / drift line wrong: $line"
fi

echo
echo "==================================================================="
echo "S5: default root resolution when NM_HOME is unset (falls back to ~/.no-mistakes)"
echo "==================================================================="
git -C "$LAB/fm-root-absent" remote set-url no-mistakes "$HOME/.no-mistakes/repos/fm.git"
out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u NM_HOME \
  FM_HOME="$LAB" FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 \
  FM_ROOT_OVERRIDE="$LAB/fm-root-absent" bin/fm-bootstrap.sh 2>&1)
if mirror_lines <<<"$out" | grep -q '^NO_MISTAKES_MIRROR: firstmate'; then
  fail "default root: a remote under ~/.no-mistakes/repos was flagged"
else
  pass "default root: remote under \$HOME/.no-mistakes/repos stays silent with NM_HOME unset"
fi
git -C "$LAB/fm-root-absent" remote set-url no-mistakes /tmp/outside-any-root/fm.git
out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u NM_HOME \
  FM_HOME="$LAB" FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 \
  FM_ROOT_OVERRIDE="$LAB/fm-root-absent" bin/fm-bootstrap.sh 2>&1)
line=$(mirror_lines <<<"$out" | grep '^NO_MISTAKES_MIRROR: firstmate' || true)
if [ "$line" = "NO_MISTAKES_MIRROR: firstmate remote=/tmp/outside-any-root/fm.git expected-root=$HOME/.no-mistakes (run no-mistakes init inside $LAB/fm-root-absent to point its gate at the active root)" ]; then
  pass "default root: drift reported against \$HOME/.no-mistakes when NM_HOME unset"
else
  fail "default-root drift line wrong: $line"
fi

echo
echo "==================================================================="
echo "S6: detect-only contract - bootstrap never mutates a clone or the registry"
echo "==================================================================="
snapshot() {
  for d in "$LAB"/projects/*/ "$LAB"/projects "$LAB"/fm-root-drift "$LAB"/fm-root-healthy "$LAB"/fm-root-absent "$LAB"/real-clone-linked; do
    [ -e "$d" ] || continue
    git -C "$d" config --local -l 2>/dev/null | sed "s|^|$(basename "$d"): |"
    git -C "$d" rev-parse HEAD 2>/dev/null | sed "s|^|$(basename "$d") HEAD: |" || true
  done
  md5sum "$LAB/data/projects.md"
}
before=$(snapshot)
# Full (non-detect-only) bootstrap flavor, network half skipped:
out=$(run_boot FM_ROOT_OVERRIDE="$LAB/fm-root-drift")
echo "--- full-flavor run mirror lines ---"
mirror_lines <<<"$out"
after=$(snapshot)
if [ "$before" = "$after" ]; then
  pass "full bootstrap run left every clone's config, every HEAD, and data/projects.md byte-identical (no init, no remote edits)"
else
  fail "bootstrap mutated clone/registry state:"
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/  /'
fi
actual=$(mirror_lines <<<"$out")
if [ "$actual" = "$expected" ]; then
  pass "full flavor prints the same 6 drift lines as the detect-only flavor"
else
  fail "full-flavor report set differs from detect-only"
fi

echo
echo "==================================================================="
echo "S7: adversarial regression - the pre-review-fix script (78297d97) on the same fixtures"
echo "==================================================================="
mkdir -p "$LAB/prefix-check"
rm -rf "$LAB/prefix-check/bin"
cp -r "$WT/bin" "$LAB/prefix-check/bin"
git show 78297d97:bin/fm-bootstrap.sh > "$LAB/prefix-check/bin/fm-bootstrap.sh"
chmod +x "$LAB/prefix-check/bin/fm-bootstrap.sh"
old_out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u NM_HOME \
  NM_HOME="$ROOT_A" FM_HOME="$LAB" FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 \
  FM_ROOT_OVERRIDE="$LAB/fm-root-drift" \
  "$LAB/prefix-check/bin/fm-bootstrap.sh" 2>&1)
old_lines=$(mirror_lines <<<"$old_out")
echo "--- OLD (78297d97) mirror lines ---"
echo "$old_lines"
echo "--- NEW (HEAD) mirror lines ---"
echo "$actual"
if grep -q '^NO_MISTAKES_MIRROR: my portal ' <<<"$old_lines"; then
  fail "pre-fix script unexpectedly reported the spaced name (regression not reproduced)"
else
  pass "regression reproduced on pre-fix script: 'my portal' never reported (registry name truncated at the space)"
fi
if grep -q '^NO_MISTAKES_MIRROR: nested ' <<<"$old_lines"; then
  pass "regression reproduced on pre-fix script: plain directory 'nested' falsely reported with the ENCLOSING repository's remote"
else
  fail "pre-fix nested false positive not reproduced"
fi
if grep -q '^NO_MISTAKES_MIRROR: nested ' <<<"$actual"; then
  fail "HEAD still reports the non-clone-root directory 'nested'"
else
  pass "HEAD stays silent for 'nested' (clone-root guard)"
fi
old_fm=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u NM_HOME \
  NM_HOME="$ROOT_A" FM_HOME="$LAB" FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 \
  FM_ROOT_OVERRIDE="$LAB/projects/nested" \
  "$LAB/prefix-check/bin/fm-bootstrap.sh" 2>&1)
new_fm=$(run_boot FM_ROOT_OVERRIDE="$LAB/projects/nested" FM_BOOTSTRAP_DETECT_ONLY=1)
echo "--- firstmate leg with FM_ROOT = plain directory inside a repository ---"
echo "OLD: $(mirror_lines <<<"$old_fm" | grep '^NO_MISTAKES_MIRROR: firstmate' || echo '(silent)')"
echo "NEW: $(mirror_lines <<<"$new_fm" | grep '^NO_MISTAKES_MIRROR: firstmate' || echo '(silent)')"
if mirror_lines <<<"$old_fm" | grep -q '^NO_MISTAKES_MIRROR: firstmate'; then
  pass "regression reproduced: pre-fix script attributed the enclosing repository's remote to the firstmate label"
else
  fail "pre-fix firstmate false positive not reproduced"
fi
if mirror_lines <<<"$new_fm" | grep -q '^NO_MISTAKES_MIRROR: firstmate'; then
  fail "HEAD still attributes a non-clone-root FM_ROOT's enclosing remote to the firstmate label"
else
  pass "HEAD silent when FM_ROOT is a plain directory nested inside a repository"
fi

echo
echo "==================================================================="
echo "S8: docs contract - read-only qualifier still follows the TANGLE sentence"
echo "==================================================================="
line_tangle=$(grep -n 'reports a `TANGLE:` line' docs/configuration.md | cut -d: -f1)
line_readonly=$(grep -n 'In a read-only session that did not get the fleet lock' docs/configuration.md | cut -d: -f1)
line_mirror=$(grep -n 'NO_MISTAKES_MIRROR' docs/configuration.md | cut -d: -f1)
echo "TANGLE at line $line_tangle, read-only qualifier at $line_readonly, NO_MISTAKES_MIRROR at $line_mirror"
if [ -n "$line_tangle" ] && [ -n "$line_readonly" ] && [ -n "$line_mirror" ] \
   && [ "$line_readonly" -eq $((line_tangle + 1)) ] && [ "$line_mirror" -gt "$line_readonly" ]; then
  pass "read-only qualifier directly follows its TANGLE sentence; NO_MISTAKES_MIRROR sentence comes after both"
else
  fail "docs sentence ordering wrong: TANGLE=$line_tangle readonly=$line_readonly mirror=$line_mirror"
fi

echo
echo "==================================================================="
echo "S9: branch contains the locally-known upstream main (conflict-free base)"
echo "==================================================================="
if git merge-base --is-ancestor origin/main HEAD; then
  pass "HEAD contains origin/main ($(git rev-parse --short origin/main)) - a merge against it cannot conflict"
else
  fail "HEAD does not contain origin/main"
fi

echo
echo "==================================================================="
echo "RESULT: $PASS passed, $FAIL failed"
echo "==================================================================="
exit $((FAIL > 0 ? 1 : 0))
