#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior and refusal tests for the worker-side merge-authority guard (bin/fm-admin-guard.sh).
#
# Hard Rule 2: "Never merge a PR without the captain's explicit word."
# Workers hitting a merge refusal must not fall back to `gh pr merge --admin`.
# This suite proves the refusal of `--admin` merges across CLI and PreToolUse entry forms,
# the allowance of non-admin commands, captain authorization detection via brief intent and env,
# the refusal when only Firstmate spec or steers author `--admin`, and the `gh` shim wrapper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-admin-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-admin-guard-tests)
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

run_guard() {
  local rc=0
  : > "$OUT"
  : > "$ERR"
  "$CHECK" "$@" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

# 1. CLI --command refusals without captain authorization
test_cli_admin_refusals() {
  local rc=0
  run_guard --command 'gh pr merge --admin' || rc=$?
  expect_code 2 "$rc" "bare gh pr merge --admin must be refused with code 2"
  assert_grep "hard-rule-2" "$ERR" "refusal must cite hard-rule-2"
  assert_grep "worker cannot use --admin" "$ERR" "refusal must explain --admin prohibition"

  rc=0
  run_guard --command 'gh pr merge 123 --admin' || rc=$?
  expect_code 2 "$rc" "gh pr merge 123 --admin must be refused"

  rc=0
  run_guard --command 'gh-axi pr merge 123 --admin' || rc=$?
  expect_code 2 "$rc" "gh-axi pr merge 123 --admin must be refused"

  rc=0
  run_guard --command 'gh pr merge -R owner/repo 123 --admin' || rc=$?
  expect_code 2 "$rc" "gh pr merge -R owner/repo 123 --admin must be refused"

  rc=0
  run_guard --command '/usr/bin/gh pr merge 123 --admin' || rc=$?
  expect_code 2 "$rc" "absolute path gh pr merge 123 --admin must be refused"

  rc=0
  run_guard --command 'git status && gh pr merge 123 --admin' || rc=$?
  expect_code 2 "$rc" "chained gh pr merge 123 --admin must be refused"

  pass "CLI --command admin merge forms are deterministically refused with code 2"
}

# 2. PreToolUse JSON transport tests across harnesses
test_pretool_harness_contracts() {
  local payload rc=0

  # Claude mode: stderr gets systemMessage JSON with deny, stdout remains empty
  payload='{"tool_input":{"command":"gh pr merge 42 --admin"}}'
  : > "$OUT"
  : > "$ERR"
  printf '%s' "$payload" | "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  expect_code 2 "$rc" "Claude PreToolUse deny must exit 2"
  [ ! -s "$OUT" ] || fail "Claude PreToolUse deny must keep stdout empty, got: $(cat "$OUT")"
  assert_grep '"permissionDecision":"deny"' "$ERR" "Claude PreToolUse deny must carry permissionDecision:deny"
  assert_grep 'hard-rule-2' "$ERR" "Claude PreToolUse deny must mention hard-rule-2"

  # Grok mode: stdout gets decision:deny JSON, exit 2
  rc=0
  payload='{"toolInput":{"command":"gh pr merge 42 --admin"}}'
  : > "$OUT"
  : > "$ERR"
  printf '%s' "$payload" | "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  expect_code 2 "$rc" "Grok PreToolUse deny must exit 2"
  assert_grep '"decision":"deny"' "$OUT" "Grok PreToolUse deny must write decision:deny to stdout"
  assert_grep 'hard-rule-2' "$OUT" "Grok PreToolUse deny must cite hard-rule-2"

  # Cursor mode: stdout gets permission:deny JSON, exit 0
  rc=0
  payload='{"tool_input":{"command":"gh pr merge 42 --admin"}}'
  : > "$OUT"
  : > "$ERR"
  printf '%s' "$payload" | "$CHECK" --cursor > "$OUT" 2> "$ERR" || rc=$?
  expect_code 0 "$rc" "Cursor PreToolUse deny must exit 0"
  assert_grep '"permission":"deny"' "$OUT" "Cursor PreToolUse deny must write permission:deny to stdout"
  assert_grep 'hard-rule-2' "$OUT" "Cursor PreToolUse deny must cite hard-rule-2"

  pass "PreToolUse hook contracts conform to Claude, Grok, and Cursor requirements"
}

# 3. Non-admin commands must be allowed
test_non_admin_commands_allowed() {
  local rc=0
  run_guard --command 'gh pr view 123' || rc=$?
  expect_code 0 "$rc" "gh pr view 123 must be allowed"

  rc=0
  run_guard --command 'gh pr merge 123' || rc=$?
  expect_code 0 "$rc" "gh pr merge 123 without --admin must be allowed by this guard"

  rc=0
  run_guard --command 'gh pr merge 123 --auto' || rc=$?
  expect_code 0 "$rc" "gh pr merge 123 --auto must be allowed"

  rc=0
  run_guard --command 'echo "gh pr merge --admin"' || rc=$?
  expect_code 0 "$rc" "echoing command string must be allowed"

  rc=0
  run_guard --command 'git status' || rc=$?
  expect_code 0 "$rc" "git status must be allowed"

  pass "non-admin commands pass through cleanly without interference"
}

# 4. Captain authorization allows --admin
test_captain_authorization() {
  local case_dir="$TMP_ROOT/captain-auth"
  mkdir -p "$case_dir/data/task-cap-1"
  local brief="$case_dir/data/task-cap-1/brief.md"

  cat <<'EOF' > "$brief"
# Task
## Captain's intent
Please merge PR 99 using --admin to bypass the stuck check.
## Firstmate spec
Run gh pr merge 99 --admin.
EOF

  local rc=0
  : > "$OUT"
  : > "$ERR"
  (
    cd "$case_dir"
    FM_TASK_ID="task-cap-1" FM_HOME="$case_dir" \
      "$CHECK" --command 'gh pr merge 99 --admin' > "$OUT" 2> "$ERR"
  ) || rc=$?
  expect_code 0 "$rc" "--admin authorized in Captain's intent must be allowed"

  # Environment authorization override
  rc=0
  : > "$OUT"
  : > "$ERR"
  FM_CAPTAIN_ADMIN_AUTH=1 "$CHECK" --command 'gh pr merge 99 --admin' > "$OUT" 2> "$ERR" || rc=$?
  expect_code 0 "$rc" "FM_CAPTAIN_ADMIN_AUTH=1 must allow --admin"

  rc=0
  : > "$OUT"
  : > "$ERR"
  FM_CAPTAIN_ADMIN_OVERRIDE=1 "$CHECK" --command 'gh pr merge 99 --admin' > "$OUT" 2> "$ERR" || rc=$?
  expect_code 0 "$rc" "FM_CAPTAIN_ADMIN_OVERRIDE=1 must allow --admin"

  pass "explicit captain authorization via brief intent or environment allows --admin"
}

# 5. Firstmate spec or steer wording does NOT authorize --admin
test_supervisor_words_do_not_authorize() {
  local case_dir="$TMP_ROOT/supervisor-hazard"
  mkdir -p "$case_dir/data/task-haz-1" "$case_dir/state/task-haz-1.inbox"
  local brief="$case_dir/data/task-haz-1/brief.md"

  # Brief where captain intent does NOT mention admin, but Firstmate spec says "land it with --admin"
  cat <<'EOF' > "$brief"
# Task
## Captain's intent
Fix the issue in the repository.
## Firstmate spec
Push branch, open PR, land it with --admin.
EOF

  # Inbox message from Firstmate supervisor also saying "land it with --admin"
  cat <<'EOF' > "$case_dir/state/task-haz-1.inbox/001.msg"
schema=fm-task-inbox.v1
--
push branch, open PR, land it with --admin
EOF

  local rc=0
  : > "$OUT"
  : > "$ERR"
  (
    cd "$case_dir"
    FM_TASK_ID="task-haz-1" FM_HOME="$case_dir" \
      "$CHECK" --command 'gh pr merge 55 --admin' > "$OUT" 2> "$ERR"
  ) || rc=$?
  expect_code 2 "$rc" "Firstmate spec or steer wording must NOT confer --admin authorization"
  assert_grep "hard-rule-2" "$ERR" "refusal must cite hard-rule-2"

  pass "supervisor spec and steer text are refused as merge authority"
}

# 6. Wrapper / shim execution mode (invoked as `gh`)
test_gh_wrapper_shim() {
  local shim_dir="$TMP_ROOT/shim-test"
  mkdir -p "$shim_dir/bin"
  ln -sf "$CHECK" "$shim_dir/bin/gh"

  local rc=0
  : > "$OUT"
  : > "$ERR"
  "$shim_dir/bin/gh" pr merge 123 --admin > "$OUT" 2> "$ERR" || rc=$?
  expect_code 2 "$rc" "gh shim must refuse pr merge --admin with code 2"
  assert_grep "hard-rule-2" "$ERR" "gh shim refusal must cite hard-rule-2"

  # Also test invocation via argv: fm-admin-guard.sh gh pr merge --admin
  rc=0
  : > "$OUT"
  : > "$ERR"
  "$CHECK" gh pr merge 123 --admin > "$OUT" 2> "$ERR" || rc=$?
  expect_code 2 "$rc" "fm-admin-guard.sh gh pr merge --admin must refuse with code 2"

  pass "gh shim wrapper intercepts and refuses unauthorized --admin merges"
}

# 7. Lint cleanliness check
test_lint_cleanliness() {
  local out
  out=$("$ROOT/bin/fm-lint.sh" "$CHECK" "${BASH_SOURCE[0]}" 2>&1) || fail "fm-admin-guard is not lint-clean: $out"
  pass "bin/fm-admin-guard.sh and its test are clean under bin/fm-lint.sh"
}

test_cli_admin_refusals
test_pretool_harness_contracts
test_non_admin_commands_allowed
test_captain_authorization
test_supervisor_words_do_not_authorize
test_gh_wrapper_shim
test_lint_cleanliness

echo "all fm-admin-guard tests passed"
