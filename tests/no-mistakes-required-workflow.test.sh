#!/usr/bin/env bash
# Behavior tests for the house-hardened "Require no-mistakes" PR body gate.
#
# .github/workflows/no-mistakes-required.yml is a house-only file with no
# upstream counterpart, so this is its only coverage. Every assertion below runs
# against executed behavior or a normalized semantic model of the workflow
# (tests/workflow-model.py), never against the raw YAML text: the gate script is
# extracted and run against synthetic events, the job's author condition is
# evaluated against synthetic authors, and the concurrency group and run name are
# rendered from the workflow's own expressions. A reworded comment therefore can
# neither break a check nor hide a regression.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
MODEL="$ROOT/tests/workflow-model.py"
MARKER='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
PR_NUMBER_FIXTURE=418

# wf <command> [args...]: query the workflow's semantic model. Returns non-zero
# when the requested path does not exist, so a deleted block (a removed
# concurrency: or if:, say) fails its test instead of rendering as empty.
wf() {
  local command=$1
  shift
  python3 "$MODEL" "$command" "$WORKFLOW" "$@"
}

# The context GitHub would supply for one pull_request_target delivery.
event_ctx() {
  printf '{"github":{"event":{"action":"%s","pull_request":{"number":%s}},"run_id":%s,"run_number":%s}}' \
    "$1" "$PR_NUMBER_FIXTURE" "$2" "$3"
}

author_ctx() {
  printf '{"github":{"event":{"pull_request":{"user":{"login":"%s"}}}}}' "$1"
}

# Run the gate's real step script against a synthetic PR body.
signature_result() {
  local body=$1 script
  script=$(wf get jobs.check.steps.0.run) ||
    fail "the gate job's first step no longer carries the signature script"
  PR_NUMBER="$PR_NUMBER_FIXTURE" PR_AUTHOR=synthetic-fork-contributor PR_BODY="$body" \
    bash -c "$script" >/dev/null 2>&1
}

test_signature_sequence_at_fixed_head() {
  signature_result "Synthetic body\n$MARKER" || fail "signed opened event must succeed"
  if signature_result 'Synthetic unsigned edit'; then
    fail "unsigned edited event must fail"
  fi
  signature_result "Synthetic signed edit\n$MARKER" || fail "signed edited event must succeed"
  pass "fixed-head signed opened, unsigned edited, signed edited yields 0/1/0"
}

# Fork safety: pull_request_target runs the base branch copy, so a PR that edits
# or deletes this workflow cannot exempt itself, and no filter may keep the check
# from being emitted on a PR that a branch protection rule requires it on.
test_trigger_is_unfiltered_pull_request_target() {
  local triggers filters types
  triggers=$(wf get on) || fail "workflow declares no triggers"
  [ "$(printf '%s' "$triggers" | jq -r 'keys | join(",")')" = pull_request_target ] ||
    fail "gate must fire on pull_request_target alone so the base branch copy always runs"
  filters=$(printf '%s' "$triggers" | jq -r '.pull_request_target | keys | join(",")')
  [ "$filters" = types ] ||
    fail "pull_request_target carries a filter beyond types ($filters); every PR must emit the check"
  types=$(printf '%s' "$triggers" | jq -r '.pull_request_target.types | sort | join(",")')
  [ "$types" = 'edited,opened,reopened,synchronize' ] ||
    fail "gate must re-run on every body-or-head change, got types: $types"
  pass "gate fires on unfiltered pull_request_target for every body and head event"
}

# Least privilege: the whole permission set is contents: read, no job widens it,
# nothing reads a secret, and no action runs - so fork head code is never
# executed and no token beyond the read-only default is ever in scope.
test_job_holds_least_privilege() {
  local model permissions jobs env_keys
  model=$(wf parse) || fail "workflow does not parse"
  permissions=$(printf '%s' "$model" | jq -c '.permissions')
  [ "$permissions" = '{"contents":"read"}' ] ||
    fail "workflow permissions must be exactly contents: read, got $permissions"
  jobs=$(printf '%s' "$model" | jq -r '.jobs | keys | join(",")')
  [ "$jobs" = check ] || fail "gate must define exactly the check job, got: $jobs"
  [ "$(printf '%s' "$model" | jq -r '.jobs.check.permissions // "absent"')" = absent ] ||
    fail "a job-level permissions block can widen the workflow's least-privilege contract"
  [ "$(printf '%s' "$model" | jq -r '.jobs.check.name')" = 'PR must be raised via no-mistakes' ] ||
    fail "stable required check name changed"
  [ "$(printf '%s' "$model" | jq -r '.jobs.check["timeout-minutes"]')" = 5 ] ||
    fail "gate lost its 5-minute timeout"
  [ "$(printf '%s' "$model" | jq -r '.jobs.check.steps | length')" = 1 ] ||
    fail "gate must run exactly one metadata-only step"
  [ "$(printf '%s' "$model" | jq -r '[.jobs.check.steps[] | select(has("uses"))] | length')" = 0 ] ||
    fail "gate must run no action at all; checking out fork head code is the hazard it avoids"
  [ "$(printf '%s' "$model" | jq -r '[.. | strings | select(test("secrets\\."))] | length')" = 0 ] ||
    fail "gate reads a secret; it must decide on the event payload alone"
  env_keys=$(printf '%s' "$model" | jq -r '.jobs.check.steps[0].env | keys | join(",")')
  [ "$env_keys" = 'PR_AUTHOR,PR_BODY,PR_NUMBER' ] ||
    fail "gate step's inputs changed, got: $env_keys"
  [ "$(printf '%s' "$model" |
    jq -r '[.jobs.check.steps[0].env[] | select(test("github\\.event\\.pull_request\\."))] | length')" = 3 ] ||
    fail "gate step must read its inputs from the pull request event payload"
  pass "gate is one metadata-only step under contents: read with no action and no secret"
}

# Release automation is exempt so the release pipeline keeps working; every other
# author - human or bot - must raise PRs through no-mistakes. Evaluating the real
# condition per author proves the exemption set exactly, including that it is not
# a loose prefix match.
test_only_release_automation_is_exempt() {
  local login expected actual
  while IFS='|' read -r login expected; do
    [ -n "$login" ] || continue
    actual=$(wf evaluate jobs.check.if "$(author_ctx "$login")") ||
      fail "gate job declares no author condition"
    [ "$actual" = "$expected" ] ||
      fail "author '$login': gate should run=$expected, got $actual"
  done <<'ROWS'
github-actions[bot]|false
dependabot[bot]|false
release-please[bot]|false
release-please|true
renovate[bot]|true
copilot[bot]|true
octocat|true
ROWS
  pass "only github-actions[bot], dependabot[bot], and release-please[bot] are exempt"
}

# GitHub concurrency groups retain at most one pending run, replacing older
# pending runs even when cancel-in-progress is false. Body-bearing events must
# therefore get an immutable per-event group so a queued run can never collapse
# an earlier opened/edited check, while head changes stay coalesced.
test_concurrency_identity_per_event() {
  local opened edited_one edited_two synchronize reopened
  opened=$(wf render concurrency.group "$(event_ctx opened 9001 71)") ||
    fail "workflow declares no concurrency group"
  edited_one=$(wf render concurrency.group "$(event_ctx edited 9002 72)")
  edited_two=$(wf render concurrency.group "$(event_ctx edited 9003 73)")
  synchronize=$(wf render concurrency.group "$(event_ctx synchronize 9004 74)")
  reopened=$(wf render concurrency.group "$(event_ctx reopened 9005 75)")

  [ "$opened" != "$edited_one" ] && [ "$opened" != "$edited_two" ] &&
    [ "$edited_one" != "$edited_two" ] ||
    fail "body events must have distinct immutable groups"
  [ "$synchronize" = "$reopened" ] ||
    fail "synchronize and reopened must coalesce into one head-change group"
  [ "$synchronize" != "$opened" ] && [ "$synchronize" != "$edited_one" ] ||
    fail "a body event reused the coalesced head-change group"
  assert_contains "$opened" "$PR_NUMBER_FIXTURE" "group does not scope to the pull request"
  assert_contains "$opened" 9001 "opened group is not keyed by its own run id"
  assert_contains "$edited_two" 9003 "edited group is not keyed by its own run id"
  [ "$(wf get concurrency.cancel-in-progress)" = true ] ||
    fail "workflow lost cancellation for coalesced head changes"
  pass "body event groups are distinct while head changes remain coalesced"
}

# The run name is how a reviewer tells two queued checks on the same PR apart, so
# it has to carry the PR, the action, the monotonic event number, and the
# immutable run id.
test_run_names_are_ordered_and_unique() {
  local first second other_action
  first=$(wf render run-name "$(event_ctx edited 9002 73)") ||
    fail "workflow declares no run name"
  second=$(wf render run-name "$(event_ctx edited 9003 74)")
  other_action=$(wf render run-name "$(event_ctx opened 9002 73)")
  [ "$first" != "$second" ] || fail "distinct events must have unique run names"
  [ "$first" != "$other_action" ] || fail "run name does not distinguish the event action"
  assert_contains "$first" "#$PR_NUMBER_FIXTURE" "run name does not identify the pull request"
  assert_contains "$first" edited "run name does not expose the event action"
  assert_contains "$first" 73 "run name does not expose the monotonic run number"
  assert_contains "$first" 9002 "run name does not expose the immutable run id"
  pass "run names expose monotonic numbers and immutable IDs"
}

test_signature_sequence_at_fixed_head
test_trigger_is_unfiltered_pull_request_target
test_job_holds_least_privilege
test_only_release_automation_is_exempt
test_concurrency_identity_per_event
test_run_names_are_ordered_and_unique
