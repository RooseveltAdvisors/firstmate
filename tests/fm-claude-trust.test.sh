#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-trust.sh and the claude spawn that calls it.
#
# Both halves of the contract are load-bearing and both are proven here: a
# legitimate fresh task worktree is trusted so a claude worker reaches its
# brief with no human, and every out-of-scope path is REFUSED rather than
# warned about or quietly skipped.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-trust)

TRUST="$ROOT/bin/fm-claude-trust.sh"

# make_case <name>: a project with one linked worktree plus an isolated Claude
# config directory. Echoes "<case>|<proj>|<wt>|<config>".
make_case() {
  local name=$1 case_dir proj wt config
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  config="$case_dir/claude-config"
  mkdir -p "$config"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s|%s|%s|%s\n' "$case_dir" "$proj" "$wt" "$config"
}

read_case() {
  IFS='|' read -r CASE_DIR PROJ WT CONFIG <<EOF
$1
EOF
}

# run_trust <config> <worktree> <project> [home]: invoke with an isolated store.
run_trust() {
  local config=$1 wt=$2 proj=$3 home=${4:-$1}
  CLAUDE_CONFIG_DIR="$config" HOME="$home" "$TRUST" "$wt" "$proj" 2>&1
}

trusted_paths() {  # <store>
  node -e 'const j=require("node:fs").existsSync(process.argv[1])?JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")):{};for(const [k,v] of Object.entries(j.projects||{})){if(v&&v.hasTrustDialogAccepted===true)console.log(k);}' "$1"
}

assert_trusted() {  # <store> <path> <msg>
  trusted_paths "$1" | grep -Fqx "$2" || fail "$3"
}

assert_not_trusted() {  # <store> <path> <msg>
  trusted_paths "$1" | grep -Fqx "$2" && fail "$3"
  return 0
}

# The store is the vendor's own persisted JSON, so preservation is asserted
# against the parsed value at a key path rather than the serialized bytes.
store_value() {  # <store> <key...> -> the JSON value at that key path
  local store=$1
  shift
  node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));let v=j;for(const k of process.argv.slice(2)){v=(v===undefined||v===null)?undefined:v[k];}console.log(JSON.stringify(v));' "$store" "$@"
}

assert_store_value() {  # <store> <expected-json> <msg> <key...>
  local store=$1 expected=$2 msg=$3 actual
  shift 3
  actual=$(store_value "$store" "$@")
  [ "$actual" = "$expected" ] || fail "$msg (expected $expected, got $actual)"
}

test_fresh_worktree_is_trusted() {
  local rec out
  rec=$(make_case fresh)
  read_case "$rec"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ")
  expect_code 0 $? "a fresh linked worktree must be trusted: $out"
  assert_contains "$out" "trusted:" "registration did not report what it trusted"
  assert_trusted "$CONFIG/.claude.json" "$WT" "the worktree was not recorded as trusted"
  # The staged write is renamed into place, so no temporary store may survive it.
  [ -z "$(find "$CONFIG" -maxdepth 1 -name '.claude.json.fm-trust.*' -print -quit)" ] \
    || fail "a temporary store file was left behind in the config directory"
  pass "fm-claude-trust.sh: a fresh task worktree is trusted"
}

test_registration_is_idempotent() {
  local rec out count
  rec=$(make_case idempotent)
  read_case "$rec"
  run_trust "$CONFIG" "$WT" "$PROJ" >/dev/null
  out=$(run_trust "$CONFIG" "$WT" "$PROJ")
  expect_code 0 $? "a repeat registration must succeed: $out"
  count=$(trusted_paths "$CONFIG/.claude.json" | grep -Fxc "$WT")
  [ "$count" = 1 ] || fail "a repeat registration duplicated the entry ($count)"
  pass "fm-claude-trust.sh: repeat registration is idempotent"
}

test_primary_checkout_is_refused() {
  local rec out
  rec=$(make_case primary)
  read_case "$rec"
  out=$(run_trust "$CONFIG" "$PROJ" "$PROJ")
  expect_code 1 $? "the primary checkout must be refused: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  assert_not_trusted "$CONFIG/.claude.json" "$PROJ" "the primary checkout was trusted"
  pass "fm-claude-trust.sh: refuses the primary checkout"
}

# CDPATH redirects a relative `cd` operand, and `git rev-parse
# --git-common-dir` answers `.git` for a primary checkout. With a decoy on
# CDPATH that also holds a `.git`, the common dir resolved for both arguments
# once landed in the decoy instead, so the git-dir-vs-common-dir comparison
# disagreed and the primary checkout was trusted.
test_cdpath_cannot_defeat_the_primary_checkout_refusal() {
  local rec out
  rec=$(make_case cdpath)
  read_case "$rec"
  mkdir -p "$CASE_DIR/decoy/.git"
  export CDPATH="$CASE_DIR/decoy"
  out=$(run_trust "$CONFIG" "$PROJ" "$PROJ")
  expect_code 1 $? "an exported CDPATH must not let the primary checkout through: $out"
  unset CDPATH
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  assert_not_trusted "$CONFIG/.claude.json" "$PROJ" "an exported CDPATH let the primary checkout be trusted"
  pass "fm-claude-trust.sh: an exported CDPATH cannot defeat the scope refusal"
}

# The primary-checkout refusal reads the worktree's git dir, so a git dir this
# user cannot resolve must refuse rather than satisfy the comparison by being
# empty. Made unresolvable by removing traversal on the linked worktree's own
# git dir, which is a real directory distinct from the shared common dir.
test_unresolvable_git_dir_is_refused() {
  local rec out gitdir
  rec=$(make_case unresolvable-gitdir)
  read_case "$rec"
  gitdir=$(git -C "$WT" rev-parse --absolute-git-dir)
  chmod 000 "$gitdir"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ")
  set -- $?
  chmod 755 "$gitdir"
  expect_code 1 "$1" "a worktree whose git dir cannot be resolved must be refused: $out"
  assert_not_trusted "$CONFIG/.claude.json" "$WT" "a worktree with an unresolvable git dir was trusted"
  pass "fm-claude-trust.sh: refuses a worktree whose git dir cannot be resolved"
}

test_home_directory_is_refused_even_when_it_is_a_worktree() {
  local rec out home
  rec=$(make_case home-worktree)
  read_case "$rec"
  # Make HOME itself a linked worktree of the project, so every git check
  # PASSES and only the home guard can refuse it. Without this the home case
  # would pass vacuously through the "not a git repository" branch.
  home="$CASE_DIR/home"
  git -C "$PROJ" worktree add --quiet -b wt-home "$home"
  out=$(run_trust "$CONFIG" "$home" "$PROJ" "$home")
  expect_code 1 $? "a home directory must be refused even as a valid worktree: $out"
  assert_contains "$out" "home directory" "the refusal did not name the home directory"
  assert_not_trusted "$CONFIG/.claude.json" "$home" "the home directory was trusted"
  # Prove the git checks really would have accepted it, so the guard above is
  # what refused rather than an unrelated failure.
  out=$(run_trust "$CONFIG" "$home" "$PROJ" "$CASE_DIR/elsewhere-home")
  expect_code 0 $? "the same path must be acceptable once it is not HOME: $out"
  pass "fm-claude-trust.sh: refuses a home directory the git checks would accept"
}

test_config_directory_is_refused() {
  local rec out
  rec=$(make_case config-dir)
  read_case "$rec"
  out=$(run_trust "$CONFIG" "$CONFIG" "$PROJ")
  expect_code 1 $? "the Claude config directory must be refused: $out"
  assert_contains "$out" "config directory" "the refusal did not name the config directory"
  pass "fm-claude-trust.sh: refuses the Claude config directory"
}

test_non_git_directory_is_refused() {
  local rec out plain
  rec=$(make_case plain)
  read_case "$rec"
  plain="$CASE_DIR/plain"
  mkdir -p "$plain"
  out=$(run_trust "$CONFIG" "$plain" "$PROJ")
  expect_code 1 $? "a plain directory must be refused: $out"
  assert_contains "$out" "not inside a git repository" "the refusal did not name the missing repository"
  assert_not_trusted "$CONFIG/.claude.json" "$plain" "a plain directory was trusted"
  pass "fm-claude-trust.sh: refuses a directory that is not a git worktree"
}

test_missing_directory_is_refused() {
  local rec out
  rec=$(make_case missing)
  read_case "$rec"
  out=$(run_trust "$CONFIG" "$CASE_DIR/nope" "$PROJ")
  expect_code 1 $? "a nonexistent path must be refused: $out"
  assert_contains "$out" "not an accessible directory" "the refusal did not name the inaccessible path"
  pass "fm-claude-trust.sh: refuses a path that does not exist"
}

test_foreign_project_worktree_is_refused() {
  local rec out other other_wt
  rec=$(make_case foreign)
  read_case "$rec"
  other="$CASE_DIR/other-project"
  other_wt="$CASE_DIR/other-wt"
  fm_git_worktree "$other" "$other_wt" wt-other
  out=$(run_trust "$CONFIG" "$other_wt" "$PROJ")
  expect_code 1 $? "another project's worktree must be refused: $out"
  assert_contains "$out" "is not a worktree of project" "the refusal did not name the project mismatch"
  assert_not_trusted "$CONFIG/.claude.json" "$other_wt" "a foreign project's worktree was trusted"
  pass "fm-claude-trust.sh: refuses a worktree belonging to another project"
}

test_worktree_subdirectory_is_refused() {
  local rec out sub
  rec=$(make_case subdir)
  read_case "$rec"
  sub="$WT/sub"
  mkdir -p "$sub"
  out=$(run_trust "$CONFIG" "$sub" "$PROJ")
  expect_code 1 $? "a subdirectory of the worktree must be refused: $out"
  assert_contains "$out" "is not a worktree root" "the refusal did not name the non-root path"
  assert_not_trusted "$CONFIG/.claude.json" "$sub" "a worktree subdirectory was trusted"
  pass "fm-claude-trust.sh: refuses a subdirectory of the worktree"
}

test_unrelated_store_content_is_preserved() {
  local rec store
  rec=$(make_case preserve)
  read_case "$rec"
  store="$CONFIG/.claude.json"
  cat > "$store" <<'JSON'
{"hasCompletedOnboarding":true,"numStartups":7,"projects":{"/other/path":{"hasTrustDialogAccepted":false,"allowedTools":["Bash"]}}}
JSON
  run_trust "$CONFIG" "$WT" "$PROJ" >/dev/null || fail "registration failed against an existing store"
  assert_trusted "$store" "$WT" "the worktree was not recorded in an existing store"
  assert_store_value "$store" true "an unrelated top-level key was lost" hasCompletedOnboarding
  assert_store_value "$store" 7 "an unrelated top-level value was changed" numStartups
  assert_store_value "$store" '["Bash"]' "another project's settings were lost" projects /other/path allowedTools
  assert_not_trusted "$store" "/other/path" "another project's trust decision was flipped"
  pass "fm-claude-trust.sh: preserves unrelated store content"
}

test_symlinked_store_is_refused() {
  local rec out foreign
  rec=$(make_case symlink-store)
  read_case "$rec"
  foreign="$CASE_DIR/foreign-store.json"
  printf '%s\n' '{"projects":{}}' > "$foreign"
  ln -s "$foreign" "$CONFIG/.claude.json"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ")
  expect_code 1 $? "a symlinked store must be refused: $out"
  assert_contains "$out" "symlink" "the refusal did not name the symlink"
  assert_not_trusted "$foreign" "$WT" "a symlinked store was followed and written"
  pass "fm-claude-trust.sh: refuses to follow a symlinked store"
}

test_corrupt_store_fails_closed() {
  local rec out store
  rec=$(make_case corrupt)
  read_case "$rec"
  store="$CONFIG/.claude.json"
  printf '%s\n' 'not json' > "$store"
  out=$(run_trust "$CONFIG" "$WT" "$PROJ")
  expect_code 1 $? "an unparseable store must be refused: $out"
  assert_grep 'not json' "$store" "the unparseable store was overwritten instead of left alone"
  pass "fm-claude-trust.sh: refuses an unparseable store and leaves it untouched"
}

# The spawn half: a real fm-spawn of a claude worker must pre-register the
# worktree AND deliver the launch command carrying the brief, with no dialog to
# answer and no human in the loop.
test_claude_spawn_pretrusts_its_worktree_and_reaches_the_brief() {
  local case_dir home proj wt config fakebin launch_log out
  case_dir="$TMP_ROOT/spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  config="$case_dir/claude-config"
  launch_log="$case_dir/launch.log"
  mkdir -p "$config"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" wt-spawn
  fm_test_spawn_brief "$home" trustspawn
  out=$(CLAUDE_CONFIG_DIR="$config" FM_FAKE_LAUNCH_LOG="$launch_log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" trustspawn "$proj" claude \
    --mode no-mistakes --yolo off)
  expect_code 0 $? "the claude spawn must succeed: $out"
  assert_trusted "$config/.claude.json" "$wt" \
    "the claude spawn did not pre-register trust for its worktree"
  assert_present "$launch_log" "the claude spawn sent no launch command"
  assert_grep 'claude --dangerously-skip-permissions' "$launch_log" \
    "the launch command was not the claude worker launch"
  assert_grep "$home/data/trustspawn/launch-brief.md" "$launch_log" \
    "the launch command did not carry the brief the worker must read"
  # The worker must read the SAME store the registration wrote, or the trust
  # would land somewhere the pane never looks.
  assert_grep "CLAUDE_CONFIG_DIR='$config'" "$launch_log" \
    "the launch command did not point the worker at the store that was trusted"
  pass "fm-spawn.sh: a claude spawn pre-trusts its worktree and launches with the brief"
}

test_fresh_worktree_is_trusted
test_registration_is_idempotent
test_primary_checkout_is_refused
test_cdpath_cannot_defeat_the_primary_checkout_refusal
test_unresolvable_git_dir_is_refused
test_home_directory_is_refused_even_when_it_is_a_worktree
test_config_directory_is_refused
test_non_git_directory_is_refused
test_missing_directory_is_refused
test_foreign_project_worktree_is_refused
test_worktree_subdirectory_is_refused
test_unrelated_store_content_is_preserved
test_symlinked_store_is_refused
test_corrupt_store_fails_closed
test_claude_spawn_pretrusts_its_worktree_and_reaches_the_brief
