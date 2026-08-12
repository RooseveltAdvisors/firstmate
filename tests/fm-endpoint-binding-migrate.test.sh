#!/usr/bin/env bash
# Regression tests for the locked, evidence-bound legacy endpoint binding
# migration and its reversible stamped-record journal.
# shellcheck disable=SC2030,SC2031
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MIGRATE="$ROOT/bin/fm-endpoint-binding-migrate.sh"
TMP_ROOT=$(fm_test_tmproot fm-endpoint-binding-migrate)
BASE_PATH=$PATH

make_case() {
  local dir=$1 fakebin
  mkdir -p "$TMP_ROOT/$dir/home/state" "$TMP_ROOT/$dir/home/config" \
    "$TMP_ROOT/$dir/worktree" "$TMP_ROOT/$dir/project" "$TMP_ROOT/$dir/fakebin"
  fakebin="$TMP_ROOT/$dir/fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  -o:comm=|-o:args=)
    [ "${4:-}" = "${FM_LOCK_PID:-}" ] && printf 'pi\n' || printf 'bash\n'
    ;;
  -o:ppid=) printf '1\n' ;;
  -t:*) exit 0 ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list-windows ]; then
  [ -z "${FM_VERIFY_STARTED:-}" ] || : > "$FM_VERIFY_STARTED"
  printf '%s\n' fm-good fm-good2 fm-dead fm-ambiguous fm-bound fm-empty
  exit 0
fi
if [ "${1:-}" = display-message ]; then
  case "${5:-}" in
    '#{pane_tty}') printf '/dev/null\n' ;;
    '#{pane_current_command}')
      case "${4:-}" in
        *fm-good|*fm-good2) printf 'pi\n' ;;
        *fm-ambiguous) printf 'mystery\n' ;;
        *) printf 'bash\n' ;;
      esac
      ;;
    '#{pane_current_path}') printf '%s\n' "${FM_LIVE_WORKTREE:-${FM_HOME%/home}/worktree}" ;;
    *) printf 'pane\n' ;;
  esac
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/ps" "$fakebin/tmux"
  printf '%s\n' "$TMP_ROOT/$dir"
}

run_locked() {
  local dir=$1
  shift
  (
    local owner=$BASHPID
    for name in ${!FM_@}; do export "${name?}"; done
    export FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_LOCK_PID="$owner"
    export FM_MIGRATE_PID="$owner"
    export PATH="$dir/fakebin:$BASE_PATH"
    printf '%s\n' "$owner" > "$dir/home/state/.lock"
    exec "$MIGRATE" "$@"
  )
}

test_evidence_bound_stamp_and_skip() {
  local dir out report
  dir=$(make_case apply)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  fm_write_meta "$dir/home/state/missing.meta" \
    'window=firstmate:fm-missing' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  fm_write_meta "$dir/home/state/dead.meta" \
    'window=firstmate:fm-dead' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  fm_write_meta "$dir/home/state/ambiguous.meta" \
    'window=firstmate:fm-ambiguous' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  fm_write_meta "$dir/home/state/mismatch.meta" \
    'window=firstmate:fm-other' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  fm_write_meta "$dir/home/state/bound.meta" \
    'window=firstmate:fm-bound' 'endpoint_task_id=bound' \
    "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  fm_write_meta "$dir/home/state/empty.meta" \
    'window=firstmate:fm-empty' 'endpoint_task_id=' \
    "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  ln -s good.meta "$dir/home/state/link.meta"
  mkdir "$dir/home/state/directory.meta"
  cp "$dir/home/state/bound.meta" "$dir/bound.before"
  cp "$dir/home/state/empty.meta" "$dir/empty.before"

  out=$(run_locked "$dir") || fail "evidence-bound migration failed: $out"
  assert_contains "$(cat "$dir/home/state/good.meta")" 'endpoint_task_id=good' \
    'live exact endpoint was not stamped'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/missing.meta" \
    || fail 'missing endpoint was stamped'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/dead.meta" \
    || fail 'dead endpoint was stamped'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/ambiguous.meta" \
    || fail 'ambiguous endpoint was stamped'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/mismatch.meta" \
    || fail 'mismatched endpoint was stamped'
  cmp -s "$dir/bound.before" "$dir/home/state/bound.meta" \
    || fail 'already-bound metadata changed'
  cmp -s "$dir/empty.before" "$dir/home/state/empty.meta" \
    || fail 'existing empty binding was overwritten'
  report=$(cat "$dir/home/state/.endpoint-binding-migration.log")
  assert_contains "$report" 'task good: stamped - exact live endpoint identity verified' 'stamp was not reported'
  assert_contains "$report" 'task missing: skipped - dead endpoint' 'dead endpoint skip was not reported'
  assert_contains "$report" 'task ambiguous: skipped - ambiguous live endpoint identity' 'ambiguous endpoint skip was not reported'
  assert_contains "$report" \
    "task mismatch: skipped - shared endpoint validation refused: REFUSED: tmux endpoint 'firstmate:fm-other' is malformed or does not belong to task mismatch; preserving task state." \
    'task identity mismatch validator refusal was not reported'
  assert_contains "$report" 'task link: skipped - metadata record is a symlink; endpoint identity is unverifiable' \
    'symlink metadata was not reported'
  assert_contains "$report" 'task directory: skipped - metadata record is not a regular file; endpoint identity is unverifiable' \
    'non-regular metadata was not reported'
  [ -L "$dir/home/state/link.meta" ] || fail 'symlink metadata was followed'
  [ -d "$dir/home/state/directory.meta" ] || fail 'non-regular metadata was changed'
  assert_contains "$(cat "$dir/home/state/.endpoint-binding-migration-records-v1")" $'good\t' \
    'stamp journal did not record the exact task'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-v1" ] \
    || fail 'completion marker hid unresolved legacy records'
  pass 'endpoint binding migration stamps only exact live identities and reports every refusal'
}

test_shared_validator_refusal_reason_is_reported() {
  local dir out report
  dir=$(make_case validator-refusals)
  fm_write_meta "$dir/home/state/missing-project.meta" \
    'window=firstmate:fm-missing-project' "worktree=$dir/worktree" 'kind=scout'
  fm_write_meta "$dir/home/state/unknown-backend.meta" \
    'window=firstmate:fm-unknown-backend' 'backend=bogus' \
    "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'

  out=$(run_locked "$dir") || fail "validator-refusal migration failed: $out"
  report=$(cat "$dir/home/state/.endpoint-binding-migration.log")
  assert_contains "$report" \
    'task missing-project: skipped - shared endpoint validation refused: REFUSED: task missing-project has a missing, empty, or ambiguous project identity; preserving task state.' \
    'missing project identity did not preserve the shared validator refusal'
  assert_contains "$report" \
    'task unknown-backend: skipped - shared endpoint validation refused: REFUSED: task unknown-backend has a missing, ambiguous, or unknown backend identity; preserving task state.' \
    'unknown backend identity did not preserve the shared validator refusal'
  assert_not_contains "$report" 'shared endpoint validation failed' \
    'specific validator refusals collapsed into a generic identity mismatch'
  pass 'endpoint binding migration preserves shared validator refusal reasons'
}

test_unreadable_metadata_is_reported() {
  local dir out report real_cat activated meta
  dir=$(make_case unreadable-meta)
  real_cat=$(command -v cat)
  activated="$dir/unreadable-activated"
  meta="$dir/home/state/unreadable.meta"
  cat > "$dir/fakebin/cat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -- ] && [ "${2:-}" = "${FM_UNREADABLE_META:?}" ]; then
  : > "${FM_UNREADABLE_ACTIVATED:?}"
  exit 1
fi
exec "${FM_REAL_CAT:?}" "$@"
SH
  chmod +x "$dir/fakebin/cat"
  fm_write_meta "$meta" \
    'window=firstmate:fm-unreadable' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  out=$(FM_REAL_CAT="$real_cat" FM_UNREADABLE_META="$meta" \
    FM_UNREADABLE_ACTIVATED="$activated" run_locked "$dir") \
    || fail "unreadable metadata scan failed: $out"
  [ -f "$activated" ] || fail 'unreadable metadata fixture did not activate'
  ! grep -q '^endpoint_task_id=' "$meta" || fail 'unreadable metadata was stamped'
  report=$(cat "$dir/home/state/.endpoint-binding-migration.log")
  assert_contains "$report" \
    'task unreadable: skipped - metadata record is unreadable; endpoint identity is unverifiable' \
    'unreadable metadata did not receive a per-record reason'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-v1" ] \
    || fail 'unreadable metadata retained completion evidence'
  pass 'endpoint binding migration reports unreadable metadata without aborting the scan'
}

test_vanished_metadata_is_reported() {
  local dir out report real_cat activated meta
  dir=$(make_case vanished-meta)
  real_cat=$(command -v cat)
  activated="$dir/vanished-activated"
  meta="$dir/home/state/vanished.meta"
  cat > "$dir/fakebin/cat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -- ] && [ "${2:-}" = "${FM_VANISHED_META:?}" ]; then
  rm -f -- "$2"
  : > "${FM_VANISHED_ACTIVATED:?}"
  exit 1
fi
exec "${FM_REAL_CAT:?}" "$@"
SH
  chmod +x "$dir/fakebin/cat"
  fm_write_meta "$meta" \
    'window=firstmate:fm-vanished' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  out=$(FM_REAL_CAT="$real_cat" FM_VANISHED_META="$meta" \
    FM_VANISHED_ACTIVATED="$activated" run_locked "$dir") \
    || fail "vanished metadata scan failed: $out"
  [ -f "$activated" ] || fail 'vanished metadata fixture did not activate'
  [ ! -e "$meta" ] || fail 'vanished metadata was recreated'
  report=$(cat "$dir/home/state/.endpoint-binding-migration.log")
  assert_contains "$report" \
    'task vanished: skipped - metadata record vanished before verification; endpoint identity is unverifiable' \
    'vanished metadata did not receive a per-record reason'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-v1" ] \
    || fail 'vanished metadata retained completion evidence'
  pass 'endpoint binding migration reports metadata that vanishes before verification'
}

test_duplicate_tmux_window_is_ambiguous() {
  local dir out report
  dir=$(make_case duplicate-tmux-window)
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list-windows ]; then
  printf '%s\n' fm-good fm-good
  exit 0
fi
if [ "${1:-}" = display-message ]; then
  case "${5:-}" in
    '#{pane_tty}') printf '/dev/null\n' ;;
    '#{pane_current_command}') printf 'pi\n' ;;
    *) printf 'pane\n' ;;
  esac
  exit 0
fi
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  out=$(run_locked "$dir") || fail "duplicate-window migration failed: $out"
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'duplicate tmux window was stamped'
  report=$(cat "$dir/home/state/.endpoint-binding-migration.log")
  assert_contains "$report" 'task good: skipped - ambiguous live endpoint identity' \
    'duplicate tmux window was not reported as ambiguous'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-v1" ] \
    || fail 'duplicate tmux window retained completion evidence'
  pass 'endpoint binding migration rejects duplicate tmux window identities'
}

test_tmux_session_prefix_is_not_an_exact_endpoint() {
  local dir out report
  dir=$(make_case tmux-session-prefix)
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list-windows ]; then
  case "${3:-}" in
    first) printf '%s\n' fm-good; exit 0 ;;
    '=first') printf '%s\n' "can't find session: first" >&2; exit 1 ;;
  esac
fi
if [ "${1:-}" = display-message ]; then
  case "${5:-}" in
    '#{pane_tty}') printf '/dev/null\n' ;;
    '#{pane_current_command}') printf 'pi\n' ;;
    *) printf 'pane\n' ;;
  esac
  exit 0
fi
exit 1
SH
  chmod +x "$dir/fakebin/tmux"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=first:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  out=$(run_locked "$dir") || fail "tmux prefix migration failed: $out"
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'tmux session prefix was accepted as an exact endpoint'
  report=$(cat "$dir/home/state/.endpoint-binding-migration.log")
  assert_contains "$report" 'task good: skipped - dead endpoint (recorded target is missing)' \
    'tmux session prefix refusal was not reported'
  pass 'endpoint binding migration requires exact tmux session targets'
}

test_tmux_name_reuse_requires_recorded_worktree() {
  local dir out report
  dir=$(make_case tmux-name-reuse)
  mkdir "$dir/other-worktree"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  out=$(FM_LIVE_WORKTREE="$dir/other-worktree" run_locked "$dir") \
    || fail "tmux name-reuse migration failed: $out"
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'reused tmux name from another worktree was stamped'
  report=$(cat "$dir/home/state/.endpoint-binding-migration.log")
  assert_contains "$report" \
    'task good: skipped - task identity mismatch: live endpoint worktree does not match recorded worktree' \
    'reused tmux name did not report the task worktree mismatch'
  pass 'endpoint binding migration binds tmux endpoints to recorded worktrees'
}

test_tmux_liveness_is_rechecked_after_worktree_read() {
  local dir out report
  dir=$(make_case tmux-dies-during-path-check)
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list-windows ]; then
  printf '%s\n' fm-good
  exit 0
fi
if [ "${1:-}" = display-message ]; then
  case "${5:-}" in
    '#{pane_tty}') printf '/dev/null\n' ;;
    '#{pane_current_command}')
      if [ -e "${FM_TMUX_PATH_READ:?}" ]; then
        : > "${FM_TMUX_RECHECKED:?}"
        printf 'bash\n'
      else
        printf 'pi\n'
      fi
      ;;
    '#{pane_current_path}')
      : > "${FM_TMUX_PATH_READ:?}"
      printf '%s\n' "${FM_HOME%/home}/worktree"
      ;;
    *) printf 'pane\n' ;;
  esac
  exit 0
fi
exit 1
SH
  chmod +x "$dir/fakebin/tmux"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'

  out=$(FM_TMUX_PATH_READ="$dir/tmux-path-read" \
    FM_TMUX_RECHECKED="$dir/tmux-liveness-rechecked" run_locked "$dir") \
    || fail "tmux liveness-change migration failed: $out"
  [ -f "$dir/tmux-path-read" ] || fail 'tmux worktree identity fixture did not activate'
  [ -f "$dir/tmux-liveness-rechecked" ] || fail 'tmux liveness recheck fixture did not activate'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'tmux endpoint that died after its worktree read was stamped'
  report=$(cat "$dir/home/state/.endpoint-binding-migration.log")
  assert_contains "$report" \
    'task good: skipped - dead endpoint (no verified agent is running)' \
    'tmux endpoint liveness change was not reported'
  pass 'endpoint binding migration rechecks tmux liveness after worktree identity'
}

test_live_legacy_herdr_endpoint_is_backfilled() {
  local dir out report
  dir=$(make_case legacy-herdr)
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  status:--json)
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  pane:get)
    printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' \
      "${3:-}" "${FM_HERDR_LIVE_WORKTREE:?}"
    ;;
  agent:get)
    printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}'
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/herdr"
  fm_write_meta "$dir/home/state/herdr-good.meta" \
    'window=lab:w1:p2' 'backend=herdr' 'herdr_session=lab' \
    'herdr_workspace_id=w1' 'herdr_tab_id=w1:t1' 'herdr_pane_id=w1:p2' \
    "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  out=$(FM_HERDR_LIVE_WORKTREE="$dir/worktree" run_locked "$dir") \
    || fail "legacy Herdr migration failed: $out"
  grep -qx 'endpoint_task_id=herdr-good' "$dir/home/state/herdr-good.meta" \
    || fail 'verified live legacy Herdr endpoint was not stamped'
  report=$(cat "$dir/home/state/.endpoint-binding-migration.log")
  assert_contains "$report" \
    'task herdr-good: stamped - exact live endpoint identity verified' \
    'verified live legacy Herdr stamp was not reported'
  pass 'endpoint binding migration backfills verified live legacy Herdr endpoints'
}

test_herdr_liveness_is_rechecked_without_server_ensure() {
  local dir out report
  dir=$(make_case herdr-dies-during-path-check)
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  status:--json)
    : > "${FM_HERDR_ENSURE_CALLED:?}"
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  pane:get)
    printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' \
      "${3:-}" "${FM_HERDR_LIVE_WORKTREE:?}"
    ;;
  agent:get)
    count=$(cat "${FM_HERDR_AGENT_COUNT:?}" 2>/dev/null || printf '0')
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_HERDR_AGENT_COUNT"
    if [ "$count" -lt 4 ]; then
      printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}'
    else
      printf '%s\n' '{"error":{"code":"agent_not_found"}}'
    fi
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/herdr"
  fm_write_meta "$dir/home/state/herdr-dead.meta" \
    'window=lab:w1:p2' 'backend=herdr' 'herdr_session=lab' \
    'herdr_workspace_id=w1' 'herdr_tab_id=w1:t1' 'herdr_pane_id=w1:p2' \
    "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  out=$(FM_HERDR_LIVE_WORKTREE="$dir/worktree" \
    FM_HERDR_AGENT_COUNT="$dir/herdr-agent-count" \
    FM_HERDR_ENSURE_CALLED="$dir/herdr-ensure-called" run_locked "$dir") \
    || fail "Herdr liveness-change migration failed: $out"
  [ ! -e "$dir/herdr-ensure-called" ] \
    || fail 'Herdr worktree identity check attempted to ensure or restart the server'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/herdr-dead.meta" \
    || fail 'Herdr endpoint that became non-live was stamped'
  report=$(cat "$dir/home/state/.endpoint-binding-migration.log")
  assert_contains "$report" \
    'task herdr-dead: skipped - dead endpoint (no verified agent is running)' \
    'Herdr endpoint liveness change was not reported'
  pass 'endpoint binding migration rechecks Herdr liveness without starting its server'
}

test_staged_binding_assembly_does_not_follow_symlinks() {
  local dir out rc real_cat outside activated
  dir=$(make_case staged-after-symlink)
  real_cat=$(command -v cat)
  outside="$dir/outside"
  activated="$dir/staged-after-race-activated"
  printf 'keep' > "$outside"
  cat > "$dir/fakebin/cat" <<'SH'
#!/usr/bin/env bash
for before in "${FM_HOME:?}"/state/.endpoint-binding-stage.*/good.before; do
  [ -f "$before" ] || continue
  for temporary in "$FM_HOME"/state/.endpoint-binding-copy.*; do
    [ -f "$temporary" ] || continue
    rm -f -- "$temporary" || exit 1
    ln -s "${FM_OUTSIDE:?}" "$temporary" || exit 1
    : > "${FM_STAGED_RACE_ACTIVATED:?}"
  done
done
exec "${FM_REAL_CAT:?}" "$@"
SH
  chmod +x "$dir/fakebin/cat"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  set +e
  out=$(FM_REAL_CAT="$real_cat" FM_OUTSIDE="$outside" \
    FM_STAGED_RACE_ACTIVATED="$activated" run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "hostile staged binding replacement unexpectedly succeeded: $out"
  [ -f "$activated" ] || fail 'staged binding replacement fixture did not activate'
  [ "$(cat "$outside")" = keep ] || fail 'staged binding assembly wrote through a symlink'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'failed staged binding assembly changed task metadata'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'failed staged binding assembly published a recovery journal'
  pass 'endpoint binding migration rejects staged binding path replacement without outside writes'
}

test_unresolved_existing_bindings_remove_completion_marker() {
  local dir out report mismatch_before empty_before duplicate_before
  dir=$(make_case unresolved-bindings)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  run_locked "$dir" >/dev/null || fail 'migration setup for unresolved binding test failed'
  fm_write_meta "$dir/home/state/mismatch.meta" \
    'window=firstmate:fm-mismatch' 'endpoint_task_id=other' \
    "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  fm_write_meta "$dir/home/state/empty.meta" \
    'window=firstmate:fm-empty' 'endpoint_task_id=' \
    "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  fm_write_meta "$dir/home/state/duplicate.meta" \
    'window=firstmate:fm-good' 'endpoint_task_id=duplicate' 'endpoint_task_id=other' \
    "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  mismatch_before=$(mktemp "$dir/mismatch.XXXXXX")
  empty_before=$(mktemp "$dir/empty.XXXXXX")
  duplicate_before=$(mktemp "$dir/duplicate.XXXXXX")
  cp "$dir/home/state/mismatch.meta" "$mismatch_before"
  cp "$dir/home/state/empty.meta" "$empty_before"
  cp "$dir/home/state/duplicate.meta" "$duplicate_before"
  out=$(run_locked "$dir") || fail "unresolved binding scan failed: $out"
  [ ! -e "$dir/home/state/.endpoint-binding-migration-v1" ] \
    || fail 'unresolved bindings retained the completion marker'
  report=$(cat "$dir/home/state/.endpoint-binding-migration.log")
  assert_contains "$report" 'task mismatch: skipped - existing endpoint_task_id binding mismatches task identity' \
    'mismatched binding reason was not reported'
  assert_contains "$report" 'task empty: skipped - existing endpoint_task_id binding is empty' \
    'empty binding reason was not reported'
  assert_contains "$report" 'task duplicate: skipped - existing endpoint_task_id binding is duplicated' \
    'duplicate binding reason was not reported'
  cmp -s "$mismatch_before" "$dir/home/state/mismatch.meta" || fail 'mismatched binding changed'
  cmp -s "$empty_before" "$dir/home/state/empty.meta" || fail 'empty binding changed'
  cmp -s "$duplicate_before" "$dir/home/state/duplicate.meta" || fail 'duplicate binding changed'
  pass 'unresolved existing bindings remove stale completion evidence'
}

test_stamp_adds_binding_as_separate_line_without_trailing_newline() {
  local dir out
  dir=$(make_case no-trailing-newline)
  printf 'window=firstmate:fm-good\nworktree=%s\nproject=%s\nkind=scout' \
    "$dir/worktree" "$dir/project" > "$dir/home/state/good.meta"
  out=$(run_locked "$dir") || fail "no-newline migration failed: $out"
  grep -qx 'endpoint_task_id=good' "$dir/home/state/good.meta" \
    || fail 'binding was not emitted as a distinct metadata line'
  ! grep -q 'kind=scoutendpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'binding was appended to the final metadata line'
  pass 'endpoint binding migration separates bindings from unterminated metadata'
}

test_hidden_metadata_is_reported() {
  local dir out report hidden_name control_name c1_name
  dir=$(make_case hidden-meta)
  hidden_name=$'.forged\nline.meta'
  control_name=$'.control\t\e.meta'
  c1_name=$'.c1-\200.meta'
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  fm_write_meta "$dir/home/state/.legacy.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  fm_write_meta "$dir/home/state/.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  fm_write_meta "$dir/home/state/$hidden_name" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  fm_write_meta "$dir/home/state/$control_name" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  fm_write_meta "$dir/home/state/$c1_name" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  out=$(run_locked "$dir") || fail "hidden metadata migration failed: $out"
  report=$(cat "$dir/home/state/.endpoint-binding-migration.log")
  assert_contains "$report" \
    'record .legacy.meta: skipped - hidden metadata record is out of scope' \
    'hidden metadata was not reported'
  assert_contains "$report" \
    'record .meta: skipped - hidden metadata record is out of scope' \
    'empty hidden metadata was not reported literally'
  assert_contains "$report" \
    'record .forged\x0Aline.meta: skipped - hidden metadata record is out of scope' \
    'newline-bearing hidden metadata was not encoded on one stable line'
  assert_contains "$report" \
    'record .control\x09\x1B.meta: skipped - hidden metadata record is out of scope' \
    'control-bearing hidden metadata was not encoded as printable data'
  assert_contains "$report" \
    'record .c1-\x80.meta: skipped - hidden metadata record is out of scope' \
    'C1 control-bearing hidden metadata was not encoded as printable data'
  [ -z "$(LC_ALL=C tr -d '\012\040-\176' < "$dir/home/state/.endpoint-binding-migration.log")" ] \
    || fail 'migration report retained non-ASCII control bytes'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/.legacy.meta" \
    || fail 'hidden metadata was stamped'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/$hidden_name" \
    || fail 'newline-bearing hidden metadata was stamped'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/$control_name" \
    || fail 'control-bearing hidden metadata was stamped'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/$c1_name" \
    || fail 'C1 control-bearing hidden metadata was stamped'
  pass 'endpoint binding migration reports hidden metadata records without stamping them'
}

test_completed_journal_is_idempotent() {
  local dir out
  dir=$(make_case completed-journal)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  run_locked "$dir" >/dev/null || fail 'migration setup for completed journal test failed'
  out=$(run_locked "$dir") || fail "completed journal rerun failed: $out"
  assert_contains "$out" 'stamped 0' 'completed journal rerun stamped a record'
  assert_contains "$(cat "$dir/home/state/good.meta")" 'endpoint_task_id=good' \
    'completed journal rerun changed the binding'
  pass 'endpoint binding migration treats a validated completed journal as idempotent'
}

test_completed_journal_merges_new_record() {
  local dir out good_before good2_before
  dir=$(make_case completed-journal-merge)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  good_before=$(mktemp "$dir/good.XXXXXX")
  cp "$dir/home/state/good.meta" "$good_before"
  run_locked "$dir" >/dev/null || fail 'initial migration for journal merge failed'
  fm_write_meta "$dir/home/state/good2.meta" \
    'window=firstmate:fm-good2' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  good2_before=$(mktemp "$dir/good2.XXXXXX")
  cp "$dir/home/state/good2.meta" "$good2_before"
  out=$(run_locked "$dir") || fail "journal merge failed: $out"
  assert_contains "$out" 'stamped 1' 'journal merge did not stamp the new record'
  assert_contains "$(cat "$dir/home/state/.endpoint-binding-migration-records-v1")" $'good\t' \
    'journal merge discarded the original record'
  assert_contains "$(cat "$dir/home/state/.endpoint-binding-migration-records-v1")" $'good2\t' \
    'journal merge did not record the new record'
  out=$(run_locked "$dir" --undo) || fail "journal merge undo failed: $out"
  cmp -s "$good_before" "$dir/home/state/good.meta" || fail 'journal merge changed the original metadata'
  cmp -s "$good2_before" "$dir/home/state/good2.meta" || fail 'journal merge undo did not restore the new metadata'
  pass 'endpoint binding migration merges new records into an existing journal'
}

test_completed_journal_recovers_orphaned_merge_backups() {
  local dir out stage good2_before
  dir=$(make_case completed-journal-crash)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  run_locked "$dir" >/dev/null || fail 'initial migration for merge crash failed'
  fm_write_meta "$dir/home/state/good2.meta" \
    'window=firstmate:fm-good2' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  good2_before=$(mktemp "$dir/good2.XXXXXX")
  cp "$dir/home/state/good2.meta" "$good2_before"
  stage="$dir/home/state/.endpoint-binding-stage.injected"
  mkdir "$stage"
  chmod 0700 "$stage"
  cp "$dir/home/state/.endpoint-binding-migration-records-v1" "$stage/records.before"
  printf '%s\n' $'good2\tgood2.before\tgood2.after' > "$stage/records"
  cp "$good2_before" "$stage/good2.before"
  cp "$dir/home/state/good2.meta" "$stage/good2.after"
  cp "$good2_before" "$dir/home/state/.endpoint-binding-migration-backups/good2.before"
  chmod 0600 "$stage"/* \
    "$dir/home/state/.endpoint-binding-migration-backups/good2.before"
  [ -f "$dir/home/state/.endpoint-binding-migration-backups/good2.before" ] \
    || fail 'merge crash did not leave the simulated orphaned backup'
  out=$(run_locked "$dir") || fail "merge restart failed: $out"
  assert_contains "$out" 'stamped 1' 'merge restart did not stamp the new record'
  assert_contains "$(cat "$dir/home/state/.endpoint-binding-migration-records-v1")" $'good2\t' \
    'merge restart did not publish the new provenance'
  pass 'endpoint binding migration recovers orphaned merge backups'
}

test_merge_abort_restores_manifest_before_backup_cleanup() {
  local dir out rc real_cp real_mv
  dir=$(make_case merge-abort-order)
  real_cp=$(command -v cp)
  real_mv=$(command -v mv)
  cat > "$dir/fakebin/cp" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAIL_RECORDS_RESTORE:-0}" -eq 1 ]; then
  case "$PWD" in
    */.endpoint-binding-stage.*)
      for arg in "$@"; do
        [ "$arg" = ./records.before ] && exit 1
      done
      ;;
  esac
fi
exec "${FM_REAL_CP:?}" "$@"
SH
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
if [ "${FM_FAIL_RECORDS_RESTORE:-0}" -eq 1 ] \
  && [ "${destination##*/}" = "${FM_RECORDS_DEST##*/}" ]; then
  count=$(cat "${FM_RECORDS_COUNT:?}" 2>/dev/null || printf '0')
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_RECORDS_COUNT"
  [ "$count" -lt 2 ] || exit 1
fi
[ -n "${FM_FAIL_DEST:-}" ] \
  && [ "${destination##*/}" = "${FM_FAIL_DEST##*/}" ] && exit 1
exec "${FM_REAL_MV:?}" "$@"
SH
  chmod +x "$dir/fakebin/cp" "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  FM_REAL_CP="$real_cp" FM_REAL_MV="$real_mv" run_locked "$dir" >/dev/null \
    || fail 'initial migration for merge abort order failed'
  fm_write_meta "$dir/home/state/good2.meta" \
    'window=firstmate:fm-good2' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  set +e
  out=$(FM_REAL_CP="$real_cp" FM_REAL_MV="$real_mv" FM_FAIL_RECORDS_RESTORE=1 \
    FM_RECORDS_DEST="$dir/home/state/.endpoint-binding-migration-records-v1" \
    FM_RECORDS_COUNT="$dir/records-publications" \
    FM_FAIL_DEST="$dir/home/state/.endpoint-binding-migration-scan-v1" run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "merge rollback failure unexpectedly succeeded: $out"
  grep -q $'^good2\t' "$dir/home/state/.endpoint-binding-migration-records-v1" \
    || fail 'failed prior-manifest restore did not retain the merged journal'
  [ -f "$dir/home/state/.endpoint-binding-migration-backups/good2.before" ] \
    && [ -f "$dir/home/state/.endpoint-binding-migration-backups/good2.after" ] \
    || fail 'failed prior-manifest restore removed merged recovery bytes'
  out=$(FM_REAL_CP="$real_cp" FM_REAL_MV="$real_mv" run_locked "$dir") \
    || fail "merge rollback recovery failed: $out"
  assert_contains "$out" 'stamped 1' 'merge rollback recovery did not rerun the new stamp'
  pass 'endpoint binding merge rollback restores provenance before cleanup'
}

test_undo_preserves_lifecycle_appends() {
  local dir out expected
  dir=$(make_case completed-journal-append)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  expected=$(mktemp "$dir/expected.XXXXXX")
  cp "$dir/home/state/good.meta" "$expected"
  run_locked "$dir" >/dev/null || fail 'initial migration for lifecycle append failed'
  printf 'control_relaunch_tx=x-link-followup\n' >> "$dir/home/state/good.meta"
  printf 'control_relaunch_tx=x-link-followup\n' >> "$expected"
  out=$(run_locked "$dir") || fail "completed journal rejected a lifecycle append: $out"
  out=$(run_locked "$dir" --undo) || fail "lifecycle append undo failed: $out"
  cmp -s "$expected" "$dir/home/state/good.meta" \
    || fail 'undo changed X-link metadata while removing its migration binding'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'undo retained the migration binding after an X-link append'
  pass 'endpoint binding undo preserves lifecycle metadata appends'
}

test_undo_skips_relaunch_owned_matching_binding() {
  local dir out relaunched
  dir=$(make_case relaunch-owned-binding)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  run_locked "$dir" >/dev/null || fail 'initial migration for relaunch ownership failed'
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' 'endpoint_task_id=good' \
    "worktree=$dir/worktree" "project=$dir/project" 'kind=scout' \
    'control_relaunch_tx=relaunch-owned'
  chmod 0600 "$dir/home/state/good.meta"
  relaunched=$(mktemp "$dir/relaunched.XXXXXX")
  cp "$dir/home/state/good.meta" "$relaunched"
  out=$(run_locked "$dir" --undo) || fail "relaunch-owned binding undo failed: $out"
  cmp -s "$relaunched" "$dir/home/state/good.meta" \
    || fail 'undo removed the lifecycle-owned relaunch binding'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'undo did not retire the relaunch-owned journal'
  pass 'endpoint binding undo skips relaunch-owned matching bindings'
}

test_undo_skips_deleted_and_changed_bindings() {
  local dir out changed
  dir=$(make_case completed-journal-retired)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  run_locked "$dir" >/dev/null || fail 'initial migration for lifecycle retirement failed'
  rm -f "$dir/home/state/good.meta"
  fm_write_meta "$dir/home/state/good2.meta" \
    'window=firstmate:fm-good2' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  out=$(run_locked "$dir") || fail "completed journal blocked a later legacy task: $out"
  assert_contains "$out" 'stamped 1' 'later eligible task was not merged after teardown deletion'
  sed 's/^endpoint_task_id=good2$/endpoint_task_id=other/' "$dir/home/state/good2.meta" > "$dir/changed"
  mv "$dir/changed" "$dir/home/state/good2.meta"
  chmod 0600 "$dir/home/state/good2.meta"
  changed=$(mktemp "$dir/changed-before-undo.XXXXXX")
  cp "$dir/home/state/good2.meta" "$changed"
  out=$(run_locked "$dir" --undo) || fail "lifecycle retirement undo failed: $out"
  [ ! -e "$dir/home/state/good.meta" ] || fail 'undo recreated teardown-deleted metadata'
  cmp -s "$changed" "$dir/home/state/good2.meta" \
    || fail 'undo removed a binding not added by the migration'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'undo did not retire the tolerant journal'
  pass 'endpoint binding undo skips deleted or changed bindings'
}

test_incomplete_apply_stage_is_cleaned_on_restart() {
  local dir out stage
  dir=$(make_case incomplete-stage)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  stage="$dir/home/state/.endpoint-binding-stage.crash"
  mkdir "$stage"
  chmod 0700 "$stage"
  cp "$dir/home/state/good.meta" "$stage/good.before"
  cp "$dir/home/state/good.meta" "$stage/good.after"
  chmod 0600 "$stage/good.before" "$stage/good.after"
  printf leftover > "$stage/report.partial"
  chmod 0600 "$stage/report.partial"
  printf stale >> "$dir/home/state/good.meta"
  mkdir "$dir/home/state/.endpoint-binding-stage.partial"
  chmod 0700 "$dir/home/state/.endpoint-binding-stage.partial"
  cp "$dir/home/state/good.meta" \
    "$dir/home/state/.endpoint-binding-stage.partial/partial.before"
  chmod 0600 "$dir/home/state/.endpoint-binding-stage.partial/partial.before"
  out=$(run_locked "$dir") || fail "incomplete stage restart failed: $out"
  [ ! -e "$stage" ] || fail 'incomplete apply stage was not cleaned'
  [ ! -e "$dir/home/state/.endpoint-binding-stage.partial" ] \
    || fail 'partial apply stage was not cleaned'
  assert_contains "$out" 'stamped 1' 'restart did not resume after incomplete stage cleanup'
  pass 'endpoint binding migration cleans incomplete pre-manifest stages'
}

test_partial_recovery_rollback_artifact_is_restart_cleanable() {
  local dir out stage
  dir=$(make_case rollback-artifact-restart)
  stage="$dir/home/state/.endpoint-binding-stage.rollback"
  mkdir "$stage"
  chmod 0700 "$stage"
  printf '%s\n' $'good\tgood.before\tgood.after' > "$stage/records"
  printf 'before\n' > "$stage/good.before"
  printf 'before\nendpoint_task_id=good\n' > "$stage/good.after"
  printf 'before\n' > "$stage/good.rollback"
  chmod 0600 "$stage/records" "$stage/good.before" "$stage/good.after" "$stage/good.rollback"
  out=$(run_locked "$dir") || fail "rollback-artifact restart failed: $out"
  [ ! -e "$stage" ] || fail 'validated rollback artifact stranded apply recovery'
  assert_contains "$out" 'stamped 0' 'rollback-artifact recovery did not rerun the scan'
  pass 'endpoint binding migration cleans completed rollback artifacts on restart'
}

test_completed_apply_stage_survives_cleanup_failure() {
  local dir out real_rm stage
  dir=$(make_case completed-apply-stage)
  real_rm=$(command -v rm)
  cat > "$dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$(pwd):$arg" in
    */state/.endpoint-binding-stage.*:./completed) exit 1 ;;
  esac
done
exec "${FM_REAL_RM:?}" "$@"
SH
  chmod +x "$dir/fakebin/rm"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  FM_REAL_RM="$real_rm" run_locked "$dir" >/dev/null \
    || fail 'migration failed when completed-stage cleanup was deferred'
  stage=$(find "$dir/home/state" -maxdepth 1 -type d -name '.endpoint-binding-stage.*' -print -quit)
  [ -n "$stage" ] || fail 'deferred cleanup lost the completed apply stage'
  [ -f "$stage/completed" ] || fail 'deferred cleanup lost durable completion state'
  printf 'control_relaunch_tx=authorized-rewrite\n' >> "$dir/home/state/good.meta"
  rm -f "$dir/fakebin/rm"
  out=$(run_locked "$dir") || fail "completed-stage restart failed: $out"
  assert_contains "$out" 'stamped 0' 'completed-stage restart reapplied a committed stamp'
  grep -qx 'control_relaunch_tx=authorized-rewrite' "$dir/home/state/good.meta" \
    || fail 'completed-stage restart changed later lifecycle metadata'
  [ ! -e "$stage" ] || fail 'completed apply stage was not retired on restart'
  pass 'endpoint binding migration durably marks completed apply stages'
}

test_completed_journal_refuses_unexpected_record() {
  local dir out rc
  dir=$(make_case completed-journal-unexpected)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  run_locked "$dir" >/dev/null || fail 'initial migration for unexpected journal failed'
  printf '%s\n' $'unexpected\tunexpected.before\tunexpected.after' >> \
    "$dir/home/state/.endpoint-binding-migration-records-v1"
  set +e
  out=$(run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unexpected journal record was accepted: $out"
  pass 'endpoint binding migration refuses unexpected journal records'
}

test_completed_journal_refuses_dangling_backup_entry() {
  local dir out rc
  dir=$(make_case dangling-backup-entry)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  run_locked "$dir" >/dev/null || fail 'initial migration for dangling backup failed'
  ln -s missing "$dir/home/state/.endpoint-binding-migration-backups/dangling"
  set +e
  out=$(run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "dangling backup entry was accepted: $out"
  pass 'endpoint binding migration refuses dangling recovery entries'
}

test_undo_recovery_rejects_symlink_destination() {
  local dir out rc stage outside
  dir=$(make_case undo-recovery-symlink)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  run_locked "$dir" >/dev/null || fail 'initial migration for recovery symlink failed'
  stage="$dir/home/state/.endpoint-binding-undo-cleanup.injected"
  mkdir "$stage"
  chmod 0700 "$stage"
  cp "$dir/home/state/.endpoint-binding-migration-records-v1" "$stage/records"
  cp "$dir/home/state/.endpoint-binding-migration-backups/good.before" "$stage/good.before"
  cp "$dir/home/state/.endpoint-binding-migration-backups/good.after" "$stage/good.after"
  chmod 0600 "$stage/records" "$stage/good.before" "$stage/good.after"
  outside="$dir/outside-recovery-target"
  rm -f "$dir/home/state/.endpoint-binding-migration-backups/good.before"
  ln -s "$outside" "$dir/home/state/.endpoint-binding-migration-backups/good.before"
  set +e
  out=$(run_locked "$dir" --undo)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "undo accepted a symlink recovery destination: $out"
  [ ! -e "$outside" ] || fail 'undo followed a symlink recovery destination'
  pass 'endpoint binding migration rejects symlink recovery destinations'
}

test_private_atomic_publication_does_not_follow_destination_symlink() {
  local dir out real_mv outside backup activated
  dir=$(make_case atomic-destination-symlink)
  real_mv=$(command -v mv)
  outside="$dir/outside-atomic-destination"
  backup="$dir/home/state/.endpoint-binding-migration-backups"
  activated="$dir/recovery-race-activated"
  mkdir "$outside"
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
if [ "$PWD" = "${FM_BACKUP_DIR:?}" ] && [ "$destination" = ./good.before ]; then
  : > "${FM_RACE_ACTIVATED:?}"
  ln -s "${FM_OUTSIDE:?}" "$destination" || exit 1
fi
exec "${FM_REAL_MV:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  out=$(FM_REAL_MV="$real_mv" FM_BACKUP_DIR="$backup" FM_OUTSIDE="$outside" \
    FM_RACE_ACTIVATED="$activated" run_locked "$dir") \
    || fail "atomic recovery publication failed: $out"
  [ -f "$activated" ] || fail 'recovery publication race fixture did not activate'
  [ -f "$backup/good.before" ] && [ ! -L "$backup/good.before" ] \
    || fail 'recovery publication retained a destination symlink'
  [ -z "$(find "$outside" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail 'recovery publication followed a destination symlink outside state'
  pass 'endpoint binding recovery atomically replaces final entries'
}

test_journal_publication_does_not_follow_destination_symlink() {
  local dir out real_mv outside records activated
  dir=$(make_case journal-destination-symlink)
  real_mv=$(command -v mv)
  outside="$dir/outside-journal-destination"
  records="$dir/home/state/.endpoint-binding-migration-records-v1"
  activated="$dir/journal-race-activated"
  mkdir "$outside"
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
if [ "$PWD" = "${FM_RECORDS%/*}" ] \
  && [ "${destination##*/}" = "${FM_RECORDS##*/}" ]; then
  : > "${FM_RACE_ACTIVATED:?}"
  ln -s "${FM_OUTSIDE:?}" "$destination" || exit 1
fi
exec "${FM_REAL_MV:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  out=$(FM_REAL_MV="$real_mv" FM_RECORDS="$records" FM_OUTSIDE="$outside" \
    FM_RACE_ACTIVATED="$activated" run_locked "$dir") \
    || fail "journal publication failed: $out"
  [ -f "$activated" ] || fail 'journal publication race fixture did not activate'
  [ -f "$records" ] && [ ! -L "$records" ] \
    || fail 'journal publication retained a destination symlink'
  [ -z "$(find "$outside" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail 'journal publication followed a destination symlink outside state'
  pass 'endpoint binding journal publication uses a no-follow destination'
}

test_evidence_publication_does_not_follow_destination_symlinks() {
  local dir out real_mv report scan
  dir=$(make_case evidence-destination-symlinks)
  real_mv=$(command -v mv)
  report="$dir/home/state/.endpoint-binding-migration.log"
  scan="$dir/home/state/.endpoint-binding-migration-scan-v1"
  mkdir "$dir/outside-report" "$dir/outside-scan"
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
case "${destination##*/}" in
  .endpoint-binding-migration.log)
    : > "${FM_REPORT_RACE_ACTIVATED:?}"
    ln -s "${FM_OUTSIDE_REPORT:?}" "$destination" || exit 1
    ;;
  .endpoint-binding-migration-scan-v1)
    : > "${FM_SCAN_RACE_ACTIVATED:?}"
    ln -s "${FM_OUTSIDE_SCAN:?}" "$destination" || exit 1
    ;;
esac
exec "${FM_REAL_MV:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  out=$(FM_REAL_MV="$real_mv" FM_OUTSIDE_REPORT="$dir/outside-report" \
    FM_OUTSIDE_SCAN="$dir/outside-scan" FM_REPORT_RACE_ACTIVATED="$dir/report-race" \
    FM_SCAN_RACE_ACTIVATED="$dir/scan-race" run_locked "$dir") \
    || fail "evidence publication failed: $out"
  [ -f "$dir/report-race" ] && [ -f "$dir/scan-race" ] \
    || fail 'evidence publication race fixtures did not activate'
  [ -f "$report" ] && [ ! -L "$report" ] \
    || fail 'report publication retained a destination symlink'
  [ -f "$scan" ] && [ ! -L "$scan" ] \
    || fail 'marker publication retained a destination symlink'
  [ -z "$(find "$dir/outside-report" "$dir/outside-scan" -mindepth 1 -print -quit)" ] \
    || fail 'evidence publication followed a destination symlink outside state'
  pass 'endpoint binding evidence publication uses no-follow destinations'
}

test_migration_does_not_require_perl() {
  local dir out
  dir=$(make_case no-perl)
  printf '#!/usr/bin/env bash\nexit 99\n' > "$dir/fakebin/perl"
  chmod +x "$dir/fakebin/perl"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  out=$(run_locked "$dir") || fail "migration required Perl: $out"
  grep -qx 'endpoint_task_id=good' "$dir/home/state/good.meta" \
    || fail 'migration without Perl did not stamp the verified endpoint'
  run_locked "$dir" --undo >/dev/null || fail 'migration without Perl could not undo'
  pass 'endpoint binding migration uses portable atomic publication'
}

test_undo_recovery_rejects_symlink_stage() {
  local dir out rc outside stage
  dir=$(make_case undo-symlink-stage)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  run_locked "$dir" >/dev/null || fail 'initial migration for symlink stage failed'
  outside="$dir/outside-undo-stage"
  mkdir "$outside"
  printf keep > "$outside/keep"
  stage="$dir/home/state/.endpoint-binding-undo-cleanup.symlink"
  ln -s "$outside" "$stage"
  set +e
  out=$(run_locked "$dir" --undo)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "undo accepted a symlinked cleanup stage: $out"
  [ -f "$outside/keep" ] || fail 'undo traversed the symlinked cleanup stage'
  pass 'endpoint binding undo rejects symlinked cleanup stages'
}

test_undo_snapshot_copy_is_atomic() {
  local dir out rc real_mv stage
  dir=$(make_case undo-snapshot-copy)
  real_mv=$(command -v mv)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
if [ "${FM_FAIL_COPY:-0}" -eq 1 ] \
  && [ "${destination##*/}" = good.after ]; then
  case "$PWD" in
    */.endpoint-binding-undo-cleanup.*) exit 1 ;;
  esac
fi
exec "${FM_REAL_MV:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  FM_REAL_MV="$real_mv" run_locked "$dir" >/dev/null \
    || fail 'migration setup for undo snapshot copy failed'
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_FAIL_COPY=1 run_locked "$dir" --undo)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "partial undo snapshot copy unexpectedly succeeded: $out"
  [ -f "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'partial undo snapshot copy lost the authoritative journal'
  [ -f "$dir/home/state/.endpoint-binding-migration-backups/good.before" ] \
    || fail 'partial undo snapshot copy lost the before evidence'
  stage=$(find "$dir/home/state" -maxdepth 1 -type d -name '.endpoint-binding-undo-cleanup.*' -print -quit)
  [ -n "$stage" ] || fail 'partial undo snapshot copy lost recovery staging'
  [ ! -e "$stage/records" ] || fail 'partial undo snapshot became recoverable evidence'
  out=$(FM_REAL_MV="$real_mv" run_locked "$dir" --undo) \
    || fail "partial undo snapshot retry failed: $out"
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'partial undo snapshot blocked a later undo'
  [ ! -e "$stage" ] || fail 'partial pre-mutation undo stage was not discarded'
  pass 'endpoint binding undo publishes readiness after complete snapshots'
}

test_undo_snapshot_rejects_replaced_stage_parent() {
  local dir out rc real_mv outside
  dir=$(make_case undo-snapshot-parent-symlink)
  real_mv=$(command -v mv)
  outside="$dir/outside-snapshot-stage"
  mkdir "$outside"
  printf 'keep\n' > "$outside/sentinel"
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
if [ "${destination##*/}" = good.current ] && [ ! -e "${FM_SWAP_SENT:?}" ]; then
  stage=$(find "${FM_STATE:?}" -maxdepth 1 -type d -name '.endpoint-binding-undo-cleanup.*' -print -quit)
  [ -n "$stage" ] || exit 1
  "${FM_REAL_MV:?}" "$stage" "$stage.held" || exit 1
  ln -s "${FM_OUTSIDE:?}" "$stage" || exit 1
  : > "$FM_SWAP_SENT"
fi
exec "${FM_REAL_MV:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  FM_REAL_MV="$real_mv" run_locked "$dir" >/dev/null \
    || fail 'migration setup for undo snapshot parent replacement failed'
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_STATE="$dir/home/state" FM_OUTSIDE="$outside" \
    FM_SWAP_SENT="$dir/stage-swapped" run_locked "$dir" --undo)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "undo accepted a replaced snapshot stage parent: $out"
  [ -f "$dir/stage-swapped" ] || fail 'snapshot stage replacement fixture did not activate'
  grep -qx 'keep' "$outside/sentinel" || fail 'undo changed the outside snapshot sentinel'
  [ ! -e "$outside/good.current" ] || fail 'undo published a current snapshot through a stage symlink'
  [ -f "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'undo discarded authoritative evidence after stage replacement'
  pass 'endpoint binding undo rejects replaced snapshot stage parents'
}

test_existing_records_snapshot_is_atomic() {
  local dir out rc records_before real_mv
  dir=$(make_case records-before-atomic)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  run_locked "$dir" >/dev/null || fail 'initial migration for atomic records snapshot failed'
  records_before=$(mktemp "$dir/records.XXXXXX")
  cp "$dir/home/state/.endpoint-binding-migration-records-v1" "$records_before"
  fm_write_meta "$dir/home/state/good2.meta" \
    'window=firstmate:fm-good2' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  real_mv=$(command -v mv)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
[ "${destination##*/}" != records.before ] || exit 1
exec "${FM_REAL_MV:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  set +e
  out=$(FM_REAL_MV="$real_mv" run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "failed records snapshot was accepted: $out"
  cmp -s "$records_before" "$dir/home/state/.endpoint-binding-migration-records-v1" \
    || fail 'failed records snapshot changed the authoritative journal'
  pass 'endpoint binding migration stages existing journal snapshots atomically'
}

test_final_live_recheck_refuses_dead_endpoint() {
  local dir out rc
  dir=$(make_case final-live-recheck)
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list-windows ]; then
  count=$(cat "${FM_LIST_COUNT:?}" 2>/dev/null || printf '0')
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_LIST_COUNT"
  if [ "$count" -ge 3 ]; then
    printf '%s\n' fm-good2 fm-dead fm-ambiguous fm-bound fm-empty
  else
    printf '%s\n' fm-good fm-good2 fm-dead fm-ambiguous fm-bound fm-empty
  fi
  exit 0
fi
if [ "${1:-}" = display-message ]; then
  case "${5:-}" in
    '#{pane_tty}') printf '/dev/null\n' ;;
    '#{pane_current_command}') printf 'pi\n' ;;
    '#{pane_current_path}') printf '%s/worktree\n' "${FM_HOME%/home}" ;;
    *) printf 'pane\n' ;;
  esac
  exit 0
fi
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  set +e
  out=$(FM_LIST_COUNT="$dir/list-count" run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "dead final endpoint rerun failed: $out"
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'dead final endpoint was stamped'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'dead final endpoint left a journal'
  assert_contains "$(cat "$dir/home/state/.endpoint-binding-migration.log")" \
    'task good: skipped - dead endpoint (recorded target is missing)' \
    'dead final endpoint lost its per-record refusal reason'
  pass 'endpoint binding migration rolls back and reports a failed final live check'
}

test_final_metadata_change_reruns_scan() {
  local dir out real_rm meta lock activated
  dir=$(make_case final-metadata-change)
  real_rm=$(command -v rm)
  meta="$dir/home/state/good.meta"
  lock="$dir/home/state/.meta-good.lock"
  activated="$dir/final-metadata-change-activated"
  cat > "$dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
trigger=0
for target in "$@"; do
  [ "$target" = "${FM_META_LOCK:?}" ] && trigger=1
done
"${FM_REAL_RM:?}" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ "$trigger" -eq 1 ] \
  && [ ! -e "${FM_RACE_ACTIVATED:?}" ]; then
  printf 'control_relaunch_tx=changed-after-staging\n' >> "${FM_META:?}"
  : > "$FM_RACE_ACTIVATED"
fi
exit "$rc"
SH
  chmod +x "$dir/fakebin/rm"
  fm_write_meta "$meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  out=$(FM_REAL_RM="$real_rm" FM_META_LOCK="$lock" FM_META="$meta" \
    FM_RACE_ACTIVATED="$activated" run_locked "$dir") \
    || fail "metadata-change rerun failed: $out"
  [ -f "$activated" ] || fail 'final metadata change fixture did not activate'
  grep -qx 'control_relaunch_tx=changed-after-staging' "$meta" \
    || fail 'metadata-change rerun lost the lifecycle update'
  grep -qx 'endpoint_task_id=good' "$meta" \
    || fail 'metadata-change rerun did not reconsider and stamp the record'
  assert_contains "$(cat "$dir/home/state/.endpoint-binding-migration.log")" \
    'task good: stamped - exact live endpoint identity verified' \
    'metadata-change rerun lost the per-record outcome'
  pass 'endpoint binding migration reruns after final metadata changes'
}

test_reverse_restores_prior_bytes() {
  local dir original out
  dir=$(make_case undo)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  original=$(mktemp "$dir/original.XXXXXX")
  cp "$dir/home/state/good.meta" "$original"
  run_locked "$dir" >/dev/null || fail 'setup migration for undo failed'
  out=$(run_locked "$dir" --undo) || fail "undo failed: $out"
  cmp -s "$original" "$dir/home/state/good.meta" || fail 'undo did not restore prior metadata bytes'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" || fail 'undo left a binding behind'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'undo left the stamp journal active'
  pass 'endpoint binding migration undo restores the exact prior metadata'
}

test_shared_task_id_grammar_reports_colon_ids() {
  local dir out
  dir=$(make_case task-id-grammar)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  fm_write_meta "$dir/home/state/colon:task.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  out=$(run_locked "$dir") || fail "task ID grammar migration failed: $out"
  assert_contains "$(cat "$dir/home/state/.endpoint-binding-migration.log")" \
    'task colon:task: skipped - invalid task id' \
    'colon task ID was not reported as an invalid record'
  assert_contains "$(cat "$dir/home/state/good.meta")" 'endpoint_task_id=good' \
    'valid task was blocked by a colon task ID'
  pass 'endpoint binding migration reports task IDs rejected by the shared lock grammar'
}

test_lock_is_required() {
  local dir rc
  dir=$(make_case unlocked)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  set +e
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH" \
    "$MIGRATE" >/dev/null 2>"$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'migration ran without the session lock'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'unlocked migration changed metadata'
  pass 'endpoint binding migration refuses without the owning session lock'
}

test_symlink_session_lock_is_refused() {
  local dir out rc
  dir=$(make_case symlink-session-lock)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  set +e
  out=$(
    owner=$BASHPID
    printf '%s\n' "$owner" > "$dir/lock-owner"
    ln -s "$dir/lock-owner" "$dir/home/state/.lock"
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_LOCK_PID="$owner" \
      PATH="$dir/fakebin:$BASE_PATH" exec "$MIGRATE"
  )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "migration accepted a symlinked session lock: $out"
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'symlink-authorized migration changed metadata'
  pass 'endpoint binding migration rejects symlinked session locks'
}

test_session_lock_symlink_swap_is_refused() {
  local dir out rc real_stat
  dir=$(make_case session-lock-symlink-swap)
  real_stat=$(command -v stat)
  cat > "$dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
path=${!#}
if [ "$path" = /dev/fd/9 ] && [ ! -e "${FM_SWAP_SENT:?}" ]; then
  out=$("${FM_REAL_STAT:?}" "$@") || exit 1
  rm -f -- "${FM_LOCK_PATH:?}" || exit 1
  ln -s "${FM_LOCK_OWNER:?}" "$FM_LOCK_PATH" || exit 1
  : > "$FM_SWAP_SENT"
  printf '%s\n' "$out"
  exit 0
fi
exec "${FM_REAL_STAT:?}" "$@"
SH
  chmod +x "$dir/fakebin/stat"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  set +e
  out=$(
    owner=$BASHPID
    printf '%s\n' "$owner" > "$dir/lock-owner"
    printf '%s\n' "$owner" > "$dir/home/state/.lock"
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_LOCK_PID="$owner" \
      FM_REAL_STAT="$real_stat" FM_LOCK_PATH="$dir/home/state/.lock" \
      FM_LOCK_OWNER="$dir/lock-owner" FM_SWAP_SENT="$dir/lock-swapped" \
      PATH="$dir/fakebin:$BASE_PATH" exec "$MIGRATE"
  )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "migration accepted a swapped session-lock symlink: $out"
  [ -L "$dir/home/state/.lock" ] || fail 'session-lock race fixture did not swap the lock path'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'symlink-swapped session lock authorized metadata changes'
  pass 'endpoint binding migration binds lock reads to ordinary files'
}

test_expired_session_lock_after_wait_is_refused() {
  local dir lock ready release waiting holder migration rc real_sleep
  dir=$(make_case expired-session-lock)
  real_sleep=$(command -v sleep)
  cat > "$dir/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_MIGRATION_WAITING:-}" ] || : > "$FM_MIGRATION_WAITING"
exec "${FM_REAL_SLEEP:?}" "$@"
SH
  chmod +x "$dir/fakebin/sleep"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  lock="$dir/home/state/.meta-good.lock"
  ready="$dir/lock-ready"
  release="$dir/lock-release"
  waiting="$dir/migration-waiting"
  (
    export FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH"
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    : > "$ready"
    while [ ! -e "$release" ]; do "$real_sleep" 0.01; done
    fm_lock_release "$lock"
  ) &
  holder=$!
  while [ ! -e "$ready" ]; do "$real_sleep" 0.01; done
  FM_REAL_SLEEP="$real_sleep" FM_MIGRATION_WAITING="$waiting" \
    run_locked "$dir" > "$dir/stdout" 2> "$dir/stderr" &
  migration=$!
  while [ ! -e "$waiting" ]; do "$real_sleep" 0.01; done
  kill -0 "$migration" 2>/dev/null || fail 'migration did not wait for the metadata lock'
  printf '999999\n' > "$dir/home/state/.lock"
  : > "$release"
  wait "$holder" || fail 'metadata lock holder failed'
  set +e
  wait "$migration"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'migration retained authority after its session lock expired'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'expired session authority changed metadata after a lock wait'
  pass 'endpoint binding migration revalidates session ownership after lock waits'
}

test_signal_rolls_back_staged_stamps() {
  local dir original out rc real_mv
  dir=$(make_case signal)
  real_mv=$(command -v mv)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
"${FM_REAL_MV:?}" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ "${destination##*/}" = "${FM_SIGNAL_META##*/}" ] \
  && [ "$PWD" = "${FM_SIGNAL_META%/*}" ] \
  && [ ! -e "${FM_SIGNAL_SENT_FILE:?}" ]; then
  : > "$FM_SIGNAL_SENT_FILE"
  kill -TERM "${FM_MIGRATE_PID:?}"
fi
exit "$rc"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  original=$(mktemp "$dir/original.XXXXXX")
  cp "$dir/home/state/good.meta" "$original"
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_SIGNAL_META="$dir/home/state/good.meta" \
    FM_SIGNAL_SENT_FILE="$dir/signal-sent" run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "interrupted migration unexpectedly succeeded: $out"
  cmp -s "$original" "$dir/home/state/good.meta" \
    || fail 'interrupted migration did not restore prior metadata bytes'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'interrupted migration left a stamp journal'
  [ ! -d "$dir/home/state/.endpoint-binding-migration-backups" ] \
    || fail 'interrupted migration left published backups'
  pass 'endpoint binding migration rolls back stamps on interruption'
}

test_final_stamp_waits_for_metadata_lock() {
  local dir lock ready release holder migration_pid rc
  dir=$(make_case metadata-lock)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  lock="$dir/home/state/.meta-good.lock"
  ready="$dir/lock-ready"
  release="$dir/lock-release"
  (
    export FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH"
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    : > "$ready"
    while [ ! -e "$release" ]; do sleep 0.01; done
    fm_lock_release "$lock"
  ) &
  holder=$!
  while [ ! -e "$ready" ]; do sleep 0.01; done
  run_locked "$dir" > "$dir/stdout" 2> "$dir/stderr" &
  migration_pid=$!
  sleep 0.2
  kill -0 "$migration_pid" 2>/dev/null || fail 'migration did not wait for the shared metadata lock'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'migration wrote metadata while the shared metadata lock was held'
  : > "$release"
  wait "$holder" || fail 'metadata lock holder failed'
  set +e
  wait "$migration_pid"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "migration failed after metadata lock release: $(cat "$dir/stderr")"
  assert_contains "$(cat "$dir/home/state/good.meta")" 'endpoint_task_id=good' \
    'migration did not stamp after the shared metadata lock was released'
  pass 'endpoint binding migration serializes final metadata replacement'
}

test_migration_transaction_lock_serializes_no_stamp_runs() {
  local dir first second
  dir=$(make_case transaction-lock)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
if [ "${destination##*/}" = "${FM_REPORT_DEST##*/}" ]; then
  if mkdir "${FM_FIRST_PUBLISH:?}" 2>/dev/null; then
    : > "${FM_FIRST_STARTED:?}"
    while [ ! -e "${FM_FIRST_RELEASE:?}" ]; do sleep 0.01; done
  else
    : > "${FM_SECOND_REACHED:?}"
  fi
fi
exec "${FM_REAL_MV:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  FM_REAL_MV="$(command -v mv)" FM_REPORT_DEST="$dir/home/state/.endpoint-binding-migration.log" \
    FM_FIRST_PUBLISH="$dir/first-publish" FM_FIRST_STARTED="$dir/first-started" \
    FM_FIRST_RELEASE="$dir/first-release" FM_SECOND_REACHED="$dir/second-reached" \
    run_locked "$dir" > "$dir/first.out" 2> "$dir/first.err" &
  first=$!
  while [ ! -e "$dir/first-started" ]; do sleep 0.01; done
  FM_REAL_MV="$(command -v mv)" FM_REPORT_DEST="$dir/home/state/.endpoint-binding-migration.log" \
    FM_FIRST_PUBLISH="$dir/first-publish" FM_FIRST_STARTED="$dir/first-started" \
    FM_FIRST_RELEASE="$dir/first-release" FM_SECOND_REACHED="$dir/second-reached" \
    run_locked "$dir" > "$dir/second.out" 2> "$dir/second.err" &
  second=$!
  sleep 0.2
  kill -0 "$second" 2>/dev/null || fail 'concurrent migration did not wait for the transaction'
  [ ! -e "$dir/second-reached" ] || fail 'concurrent migration entered evidence publication'
  : > "$dir/first-release"
  wait "$first" || fail "first serialized migration failed: $(cat "$dir/first.err")"
  wait "$second" || fail "second serialized migration failed: $(cat "$dir/second.err")"
  pass 'endpoint binding migration serializes each home transaction'
}

test_stamp_lock_is_held_through_publication_rollback() {
  local dir migration writer rc lock
  dir=$(make_case stamp-commit-lock)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
if [ -n "${FM_SCAN_DEST:-}" ] \
  && [ "${destination##*/}" = "${FM_SCAN_DEST##*/}" ]; then
  : > "${FM_PUBLICATION_STARTED:?}"
  while [ ! -e "${FM_PUBLICATION_RELEASE:?}" ]; do sleep 0.01; done
  exit 1
fi
exec "${FM_REAL_MV:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  FM_REAL_MV="$(command -v mv)" FM_SCAN_DEST="$dir/home/state/.endpoint-binding-migration-scan-v1" \
    FM_PUBLICATION_STARTED="$dir/publication-started" FM_PUBLICATION_RELEASE="$dir/publication-release" \
    run_locked "$dir" > "$dir/migration.out" 2> "$dir/migration.err" &
  migration=$!
  while [ ! -e "$dir/publication-started" ]; do sleep 0.01; done
  lock="$dir/home/state/.meta-good.lock"
  (
    export FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH"
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$lock"
    printf 'control_relaunch_tx=concurrent\n' >> "$dir/home/state/good.meta"
    fm_lock_release "$lock"
  ) &
  writer=$!
  sleep 0.2
  kill -0 "$writer" 2>/dev/null || fail 'lifecycle writer bypassed the migration metadata lock'
  ! grep -q '^control_relaunch_tx=concurrent$' "$dir/home/state/good.meta" \
    || fail 'lifecycle writer changed metadata before migration commit'
  : > "$dir/publication-release"
  set +e
  wait "$migration"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'forced publication failure unexpectedly succeeded'
  wait "$writer" || fail 'lifecycle writer failed after migration rollback'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'publication rollback retained the migration binding'
  grep -qx 'control_relaunch_tx=concurrent' "$dir/home/state/good.meta" \
    || fail 'publication rollback overwrote the later lifecycle update'
  pass 'endpoint binding migration holds new metadata locks through commit'
}

test_identity_verification_waits_for_metadata_lock() {
  local dir lock ready release holder migration_pid rc verify_started
  dir=$(make_case identity-lock)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  lock="$dir/home/state/.meta-good.lock"
  ready="$dir/lock-ready"
  release="$dir/lock-release"
  verify_started="$dir/verify-started"
  (
    export FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH"
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    : > "$ready"
    while [ ! -e "$release" ]; do sleep 0.01; done
    fm_lock_release "$lock"
  ) &
  holder=$!
  while [ ! -e "$ready" ]; do sleep 0.01; done
  FM_VERIFY_STARTED="$verify_started" run_locked "$dir" > "$dir/stdout" 2> "$dir/stderr" &
  migration_pid=$!
  sleep 0.2
  kill -0 "$migration_pid" 2>/dev/null || fail 'migration did not wait for the identity metadata lock'
  [ ! -e "$verify_started" ] || fail 'identity verification ran before the metadata lock was released'
  : > "$release"
  wait "$holder" || fail 'identity metadata lock holder failed'
  set +e
  wait "$migration_pid"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "migration failed after identity lock release: $(cat "$dir/stderr")"
  [ -e "$verify_started" ] || fail 'identity verification did not run after lock release'
  pass 'endpoint identity verification and staging share the metadata lock'
}

test_report_write_failure_aborts_before_stamping() {
  local dir original out rc real_mv outside activated
  dir=$(make_case report-write-failure)
  real_mv=$(command -v mv)
  outside="$dir/outside-report"
  activated="$dir/report-write-race-activated"
  printf 'keep\n' > "$outside"
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
case "${destination##*/}" in
  report.evidence.*) ;;
  report.*)
    case "$PWD" in
      */.endpoint-binding-stage.*)
        rm -f -- "$destination" || exit 1
        ln -s "${FM_OUTSIDE:?}" "$destination" || exit 1
        : > "${FM_RACE_ACTIVATED:?}"
        exit 1
        ;;
    esac
    ;;
esac
exec "${FM_REAL_MV:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  original=$(mktemp "$dir/original.XXXXXX")
  cp "$dir/home/state/good.meta" "$original"
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_OUTSIDE="$outside" FM_RACE_ACTIVATED="$activated" \
    run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "report write failure unexpectedly succeeded: $out"
  [ -f "$activated" ] || fail 'report write race fixture did not activate'
  [ "$(cat "$outside")" = keep ] || fail 'report append wrote through a replaced temporary'
  cmp -s "$original" "$dir/home/state/good.meta" || fail 'report write failure left stamped metadata'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'report write failure published a stamp journal'
  pass 'endpoint binding migration aborts before stamping when outcome reporting fails'
}

test_undo_waits_for_metadata_lock() {
  local dir lock ready release holder migration_pid rc
  dir=$(make_case undo-metadata-lock)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  run_locked "$dir" >/dev/null || fail 'migration setup for undo lock test failed'
  lock="$dir/home/state/.meta-good.lock"
  ready="$dir/lock-ready"
  release="$dir/lock-release"
  (
    export FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH"
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    : > "$ready"
    while [ ! -e "$release" ]; do sleep 0.01; done
    fm_lock_release "$lock"
  ) &
  holder=$!
  while [ ! -e "$ready" ]; do sleep 0.01; done
  run_locked "$dir" --undo > "$dir/stdout" 2> "$dir/stderr" &
  migration_pid=$!
  sleep 0.2
  kill -0 "$migration_pid" 2>/dev/null || fail 'undo did not wait for the shared metadata lock'
  assert_contains "$(cat "$dir/home/state/good.meta")" 'endpoint_task_id=good' \
    'undo changed metadata while the shared metadata lock was held'
  : > "$release"
  wait "$holder" || fail 'undo metadata lock holder failed'
  set +e
  wait "$migration_pid"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "undo failed after metadata lock release: $(cat "$dir/stderr")"
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'undo did not restore metadata after the shared lock was released'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'undo left the journal after the lock was released'
  pass 'endpoint binding undo serializes metadata replacement'
}

test_undo_signal_restores_stamped_bytes() {
  local dir original_good original_good2 stamped_good stamped_good2 out rc real_mv
  dir=$(make_case undo-signal)
  real_mv=$(command -v mv)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
"${FM_REAL_MV:?}" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ -n "${FM_UNDO_SIGNAL_META:-}" ] \
  && [ "${destination##*/}" = "${FM_UNDO_SIGNAL_META##*/}" ] \
  && [ "$PWD" = "${FM_UNDO_SIGNAL_META%/*}" ] \
  && [ "${FM_UNDO_SIGNAL:-0}" -eq 1 ] && [ ! -e "${FM_UNDO_SIGNAL_SENT:?}" ]; then
  : > "$FM_UNDO_SIGNAL_SENT"
  kill -TERM "${FM_MIGRATE_PID:?}"
fi
exit "$rc"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  fm_write_meta "$dir/home/state/good2.meta" \
    'window=firstmate:fm-good2' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  original_good=$(mktemp "$dir/original-good.XXXXXX")
  original_good2=$(mktemp "$dir/original-good2.XXXXXX")
  cp "$dir/home/state/good.meta" "$original_good"
  cp "$dir/home/state/good2.meta" "$original_good2"
  FM_REAL_MV="$real_mv" run_locked "$dir" >/dev/null \
    || fail 'migration setup for undo signal test failed'
  stamped_good=$(mktemp "$dir/stamped-good.XXXXXX")
  stamped_good2=$(mktemp "$dir/stamped-good2.XXXXXX")
  cp "$dir/home/state/good.meta" "$stamped_good"
  cp "$dir/home/state/good2.meta" "$stamped_good2"
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_UNDO_SIGNAL=1 \
    FM_UNDO_SIGNAL_META="$dir/home/state/good2.meta" \
    FM_UNDO_SIGNAL_SENT="$dir/undo-signal-sent" run_locked "$dir" --undo)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "interrupted undo unexpectedly succeeded: $out"
  cmp -s "$stamped_good" "$dir/home/state/good.meta" \
    || fail 'interrupted undo left the first metadata record partially undone'
  cmp -s "$stamped_good2" "$dir/home/state/good2.meta" \
    || fail 'interrupted undo left the signaled metadata record partially undone'
  [ -f "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'interrupted undo discarded the journal'
  [ -d "$dir/home/state/.endpoint-binding-migration-backups" ] \
    || fail 'interrupted undo discarded before/after evidence'
  out=$(FM_REAL_MV="$real_mv" run_locked "$dir" --undo) \
    || fail "retry after interrupted undo failed: $out"
  cmp -s "$original_good" "$dir/home/state/good.meta" || fail 'retry did not restore first metadata bytes'
  cmp -s "$original_good2" "$dir/home/state/good2.meta" || fail 'retry did not restore second metadata bytes'
  pass 'endpoint binding undo restores stamped bytes after interruption'
}

test_crashed_undo_restores_current_snapshot_before_apply() {
  local dir out rc real_mv stage
  dir=$(make_case crashed-undo-recovery)
  real_mv=$(command -v mv)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
"${FM_REAL_MV:?}" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ -n "${FM_CRASH_DEST:-}" ] \
  && [ "${destination##*/}" = "${FM_CRASH_DEST##*/}" ] \
  && [ "$PWD" = "${FM_CRASH_DEST%/*}" ]; then
  kill -KILL "${FM_MIGRATE_PID:?}"
fi
exit "$rc"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  FM_REAL_MV="$real_mv" run_locked "$dir" >/dev/null \
    || fail 'migration setup for crashed undo recovery failed'
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_CRASH_DEST="$dir/home/state/good.meta" \
    run_locked "$dir" --undo)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "crashed undo unexpectedly succeeded: $out"
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'crashed undo did not reach the partial metadata change'
  stage=$(find "$dir/home/state" -maxdepth 1 -type d \
    -name '.endpoint-binding-undo-cleanup.*' -print -quit)
  [ -n "$stage" ] || fail 'crashed undo lost its recovery stage'
  rm -f "$dir/fakebin/mv"
  out=$(run_locked "$dir") || fail "apply could not recover crashed undo: $out"
  assert_contains "$out" 'stamped 0' 'crashed undo recovery reapplied the recorded stamp'
  grep -qx 'endpoint_task_id=good' "$dir/home/state/good.meta" \
    || fail 'apply did not restore the pre-undo metadata snapshot'
  [ ! -e "$stage" ] || fail 'apply did not retire the recovered undo stage'
  out=$(run_locked "$dir" --undo) || fail "undo after crash recovery failed: $out"
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'undo after crash recovery retained the binding'
  pass 'incomplete undo recovery restores current snapshots before apply'
}

test_undo_signal_during_cleanup_restores_recovery_state() {
  local dir original stamped out rc real_mv real_rm
  dir=$(make_case undo-cleanup-signal)
  real_rm=$(command -v rm)
  cat > "$dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
"${FM_REAL_RM:?}" "$@"
rc=$?
  if [ "$rc" -eq 0 ] && [ "${FM_UNDO_CLEANUP_SIGNAL:-0}" -eq 1 ] \
    && [ ! -e "${FM_UNDO_CLEANUP_SIGNAL_SENT:?}" ]; then
    for arg in "$@"; do
      if [ "$arg" = "${FM_UNDO_CLEANUP_SIGNAL_PATH:-}" ] \
        || [ "${arg##*/}" = "${FM_UNDO_CLEANUP_SIGNAL_PATH##*/}" ]; then
      : > "$FM_UNDO_CLEANUP_SIGNAL_SENT"
      kill -TERM "${FM_MIGRATE_PID:?}"
      break
    fi
  done
fi
exit "$rc"
SH
  chmod +x "$dir/fakebin/rm"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  original=$(mktemp "$dir/original.XXXXXX")
  cp "$dir/home/state/good.meta" "$original"
  FM_REAL_RM="$real_rm" run_locked "$dir" >/dev/null || fail 'migration setup for cleanup signal failed'
  stamped=$(mktemp "$dir/stamped.XXXXXX")
  cp "$dir/home/state/good.meta" "$stamped"
  set +e
  out=$(FM_REAL_RM="$real_rm" FM_UNDO_CLEANUP_SIGNAL=1 \
    FM_UNDO_CLEANUP_SIGNAL_PATH="$dir/home/state/.endpoint-binding-migration-backups/good.after" \
    FM_UNDO_CLEANUP_SIGNAL_SENT="$dir/undo-cleanup-signal-sent" run_locked "$dir" --undo)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup interruption unexpectedly succeeded: $out"
  cmp -s "$stamped" "$dir/home/state/good.meta" \
    || fail "cleanup interruption left metadata partially undone: $(cat "$dir/home/state/good.meta")"
  [ -f "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'cleanup interruption discarded the journal'
  [ -f "$dir/home/state/.endpoint-binding-migration-backups/good.after" ] \
    || fail 'cleanup interruption discarded the after-bytes'
  out=$(FM_REAL_RM="$real_rm" run_locked "$dir" --undo) \
    || fail "cleanup interruption retry failed: $out"
  cmp -s "$original" "$dir/home/state/good.meta" || fail 'cleanup interruption retry did not undo metadata'
  pass 'endpoint binding undo remains transactional through cleanup interruption'
}

test_publication_failure_restores_evidence() {
  local dir original original_report out rc real_mv outside
  dir=$(make_case publication-failure)
  real_mv=$(command -v mv)
  outside="$dir/outside-evidence-restore"
  mkdir "$outside"
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
if [ -n "${FM_FAIL_DEST:-}" ] \
  && [ "${destination##*/}" = "${FM_FAIL_DEST##*/}" ]; then
  : > "${FM_PUBLICATION_FAILED:?}"
  exit 1
fi
if [ -n "${FM_RESTORE_DEST:-}" ] && [ -e "${FM_PUBLICATION_FAILED:?}" ] \
  && [ "$PWD" = "${FM_RESTORE_DEST%/*}" ] \
  && [ "${destination##*/}" = "${FM_RESTORE_DEST##*/}" ] \
  && [ ! -e "${FM_RESTORE_RACE_ACTIVATED:?}" ]; then
  rm -f -- "$destination" || exit 1
  ln -s "${FM_OUTSIDE:?}" "$destination" || exit 1
  : > "$FM_RESTORE_RACE_ACTIVATED"
fi
exec "${FM_REAL_MV:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  printf 'old report\n' > "$dir/home/state/.endpoint-binding-migration.log"
  chmod 0600 "$dir/home/state/.endpoint-binding-migration.log"
  original=$(mktemp "$dir/original.XXXXXX")
  original_report=$(mktemp "$dir/original-report.XXXXXX")
  cp "$dir/home/state/good.meta" "$original"
  cp "$dir/home/state/.endpoint-binding-migration.log" "$original_report"
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_FAIL_DEST="$dir/home/state/.endpoint-binding-migration-scan-v1" \
    FM_RESTORE_DEST="$dir/home/state/.endpoint-binding-migration.log" \
    FM_PUBLICATION_FAILED="$dir/evidence-publication-failed" \
    FM_RESTORE_RACE_ACTIVATED="$dir/evidence-restore-race-activated" FM_OUTSIDE="$outside" \
    run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "publication failure unexpectedly succeeded: $out"
  cmp -s "$original" "$dir/home/state/good.meta" || fail 'publication failure left stamped metadata'
  cmp -s "$original_report" "$dir/home/state/.endpoint-binding-migration.log" \
    || fail 'publication failure left a stale report'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-scan-v1" ] \
    || fail 'publication failure left a stale scan marker'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-v1" ] \
    || fail 'publication failure left a stale completion marker'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'publication failure left a stale stamp journal'
  [ -f "$dir/evidence-restore-race-activated" ] \
    || fail 'evidence restoration race fixture did not activate'
  [ -z "$(find "$outside" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail 'evidence restoration followed a destination symlink outside state'
  pass 'endpoint binding migration rolls back published evidence on failure'
}

test_abort_interruption_retains_recovery_stage() {
  local dir out rc real_mv real_rm stage
  dir=$(make_case abort-interruption)
  real_mv=$(command -v mv)
  real_rm=$(command -v rm)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
if [ "${destination##*/}" = "${FM_FAIL_DEST##*/}" ] \
  && [ ! -e "${FM_FAIL_SENT:?}" ]; then
  : > "$FM_FAIL_SENT"
  exit 1
fi
exec "${FM_REAL_MV:?}" "$@"
SH
  cat > "$dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "${arg##*/}" = good.before ] && [ "${FM_ABORT_SIGNAL:-0}" -eq 1 ] \
    && [ ! -e "${FM_ABORT_SIGNAL_SENT:?}" ]; then
    : > "$FM_ABORT_SIGNAL_SENT"
    kill -TERM "${FM_MIGRATE_PID:?}"
    exit 143
  fi
done
exec "${FM_REAL_RM:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv" "$dir/fakebin/rm"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_REAL_RM="$real_rm" \
    FM_FAIL_DEST="$dir/home/state/.endpoint-binding-migration-scan-v1" \
    FM_FAIL_SENT="$dir/publication-failed" FM_ABORT_SIGNAL=1 \
    FM_ABORT_SIGNAL_SENT="$dir/abort-signal-sent" run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "abort interruption unexpectedly succeeded: $out"
  [ -f "$dir/abort-signal-sent" ] || fail 'abort interruption fixture did not activate'
  stage=$(find "$dir/home/state" -maxdepth 1 -type d \
    -name '.endpoint-binding-stage.*' -print -quit)
  [ -n "$stage" ] || fail 'abort interruption discarded recovery staging'
  [ -f "$stage/good.before" ] && [ -f "$stage/good.after" ] \
    || fail 'abort interruption discarded staged recovery bytes'
  rm -f "$dir/fakebin/mv" "$dir/fakebin/rm"
  out=$(run_locked "$dir") || fail "abort interruption recovery failed: $out"
  assert_contains "$out" 'stamped 1' 'abort interruption recovery did not rerun migration'
  [ ! -e "$stage" ] || fail 'abort interruption recovery left stale staging'
  pass 'endpoint binding abort retains recovery staging until cleanup commits'
}

test_backup_cleanup_failure_retains_staged_recovery() {
  local dir out rc real_mv real_rm stage
  dir=$(make_case backup-cleanup-failure)
  real_mv=$(command -v mv)
  real_rm=$(command -v rm)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
if [ "${destination##*/}" = "${FM_FAIL_DEST##*/}" ]; then exit 1; fi
exec "${FM_REAL_MV:?}" "$@"
SH
  cat > "$dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
fail_target=${FM_FAIL_RM:-}
fail_target=${fail_target##*/}
for arg in "$@"; do
  [ "$arg" = "${FM_FAIL_RM:-}" ] || [ "${arg##*/}" = "$fail_target" ] && exit 1
done
exec "${FM_REAL_RM:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv" "$dir/fakebin/rm"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_REAL_RM="$real_rm" \
    FM_FAIL_DEST="$dir/home/state/.endpoint-binding-migration-scan-v1" \
    FM_FAIL_RM="$dir/home/state/.endpoint-binding-migration-backups/good.after" run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "backup cleanup failure unexpectedly succeeded: $out"
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'backup cleanup failure left stamped metadata'
  stage=$(find "$dir/home/state" -maxdepth 1 -type d -name '.endpoint-binding-stage.*' -print -quit)
  [ -n "$stage" ] || fail 'backup cleanup failure discarded staged recovery evidence'
  pass 'endpoint binding rollback retains staged recovery when backup cleanup fails'
}

test_rollback_rejects_replaced_backup_directory_symlink() {
  local dir out rc real_mv
  dir=$(make_case rollback-backup-symlink)
  real_mv=$(command -v mv)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
if [ "${destination##*/}" = "${FM_FAIL_DEST##*/}" ]; then
  "${FM_REAL_RM:?}" -rf -- "$FM_BACKUP_DIR"
  mkdir -- "$FM_OUTSIDE"
  ln -s "$FM_OUTSIDE" "$FM_BACKUP_DIR"
  exit 1
fi
exec "${FM_REAL_MV:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_REAL_RM="$(command -v rm)" \
    FM_FAIL_DEST="$dir/home/state/.endpoint-binding-migration-scan-v1" \
    FM_BACKUP_DIR="$dir/home/state/.endpoint-binding-migration-backups" \
    FM_OUTSIDE="$dir/outside-recovery" run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "rollback accepted a replaced backup symlink: $out"
  [ -L "$dir/home/state/.endpoint-binding-migration-backups" ] \
    || fail 'rollback test did not replace the backup directory'
  [ ! -e "$dir/outside-recovery/good.before" ] \
    || fail 'rollback followed a replaced backup directory symlink'
  [ ! -e "$dir/outside-recovery/good.after" ] \
    || fail 'rollback followed a replaced backup directory symlink'
  pass 'endpoint binding rollback fails closed on a replaced backup symlink'
}

test_recovery_journal_copy_is_atomic() {
  local dir out rc real_mv stage
  dir=$(make_case recovery-journal-copy)
  real_mv=$(command -v mv)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
if [ "${FM_FAIL_COPY:-0}" -eq 1 ] \
  && [ "${destination##*/}" = .endpoint-binding-migration-records-v1 ]; then
  exit 1
fi
exec "${FM_REAL_MV:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  FM_REAL_MV="$real_mv" run_locked "$dir" >/dev/null \
    || fail 'migration setup for atomic recovery copy failed'
  stage="$dir/home/state/.endpoint-binding-undo-cleanup.injected"
  mkdir "$stage"
  chmod 0700 "$stage"
  cp "$dir/home/state/.endpoint-binding-migration-records-v1" "$stage/records"
  cp "$dir/home/state/.endpoint-binding-migration-backups/good.before" "$stage/good.before"
  cp "$dir/home/state/.endpoint-binding-migration-backups/good.after" "$stage/good.after"
  chmod 0600 "$stage/records" "$stage/good.before" "$stage/good.after"
  rm -f "$dir/home/state/.endpoint-binding-migration-records-v1"
  rm -f "$dir/home/state/.endpoint-binding-migration-backups/good.before" \
    "$dir/home/state/.endpoint-binding-migration-backups/good.after"
  rmdir "$dir/home/state/.endpoint-binding-migration-backups"
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_FAIL_COPY=1 run_locked "$dir" --undo)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "partial recovery journal copy unexpectedly succeeded: $out"
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'partial recovery copy published a truncated journal'
  pass 'endpoint binding recovery stages journal copies atomically'
}

test_crash_after_manifest_preserves_undo_path() {
  local dir out rc real_mv stage
  dir=$(make_case crash-before-stamp)
  real_mv=$(command -v mv)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
"${FM_REAL_MV:?}" "$@"
rc=$?
if [ "$rc" -eq 0 ] \
  && [ "${destination##*/}" = "${FM_CRASH_DEST##*/}" ]; then
  kill -KILL "${FM_MIGRATE_PID:?}"
fi
exit "$rc"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  set +e
  out=$(FM_REAL_MV="$real_mv" \
    FM_CRASH_DEST="$dir/home/state/.endpoint-binding-migration-records-v1" run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "manifest crash unexpectedly succeeded: $out"
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'manifest crash left metadata stamped without an apply'
  [ -f "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'manifest crash discarded the durable journal'
  [ -f "$dir/home/state/.endpoint-binding-migration-backups/good.before" ] \
    || fail 'manifest crash discarded before recovery bytes'
  stage=$(find "$dir/home/state" -maxdepth 1 -type d \
    -name '.endpoint-binding-stage.*' -print -quit)
  [ -n "$stage" ] || fail 'manifest crash did not retain its apply recovery stage'
  rm -f "$dir/fakebin/mv"
  out=$(run_locked "$dir" --undo) || fail "manifest crash recovery undo failed: $out"
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'manifest crash recovery left the journal'
  [ ! -e "$stage" ] || fail 'undo left stale partial-apply recovery evidence'
  pass 'endpoint binding migration publishes recovery state before stamping'
}

test_crash_recovery_restores_evidence_snapshots() {
  local dir out rc real_mv original_meta original_report original_scan original_marker
  dir=$(make_case crash-evidence)
  real_mv=$(command -v mv)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
if [ -n "${FM_FAIL_DEST:-}" ] \
  && [ "${destination##*/}" = "${FM_FAIL_DEST##*/}" ]; then
  if [ -e "${FM_FAIL_SENT:-}" ]; then
    exit 1
  fi
  : > "$FM_FAIL_SENT"
fi
"${FM_REAL_MV:?}" "$@"
rc=$?
if [ "$rc" -eq 0 ] \
  && [ "${destination##*/}" = "${FM_KILL_DEST##*/}" ] \
  && [ ! -e "${FM_KILL_SENT:?}" ]; then
  : > "$FM_KILL_SENT"
  kill -KILL "${FM_MIGRATE_PID:?}"
fi
exit "$rc"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  printf 'old report\n' > "$dir/home/state/.endpoint-binding-migration.log"
  printf 'old scan\n' > "$dir/home/state/.endpoint-binding-migration-scan-v1"
  printf 'old marker\n' > "$dir/home/state/.endpoint-binding-migration-v1"
  chmod 0600 "$dir/home/state/.endpoint-binding-migration.log" \
    "$dir/home/state/.endpoint-binding-migration-scan-v1" \
    "$dir/home/state/.endpoint-binding-migration-v1"
  original_meta=$(mktemp "$dir/meta.XXXXXX")
  original_report=$(mktemp "$dir/report.XXXXXX")
  original_scan=$(mktemp "$dir/scan.XXXXXX")
  original_marker=$(mktemp "$dir/marker.XXXXXX")
  cp "$dir/home/state/good.meta" "$original_meta"
  cp "$dir/home/state/.endpoint-binding-migration.log" "$original_report"
  cp "$dir/home/state/.endpoint-binding-migration-scan-v1" "$original_scan"
  cp "$dir/home/state/.endpoint-binding-migration-v1" "$original_marker"
  set +e
  out=$(FM_REAL_MV="$real_mv" \
    FM_KILL_DEST="$dir/home/state/.endpoint-binding-migration-scan-v1" \
    FM_KILL_SENT="$dir/crash-sent" run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "evidence crash unexpectedly succeeded: $out"
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_FAIL_DEST="$dir/home/state/good.meta" \
    FM_FAIL_SENT="$dir/fail-sent" run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "post-recovery failure unexpectedly succeeded: $out"
  cmp -s "$original_meta" "$dir/home/state/good.meta" || fail 'crash recovery left metadata changed'
  cmp -s "$original_report" "$dir/home/state/.endpoint-binding-migration.log" \
    || fail 'crash recovery left a stale report'
  cmp -s "$original_scan" "$dir/home/state/.endpoint-binding-migration-scan-v1" \
    || fail 'crash recovery left a stale scan marker'
  cmp -s "$original_marker" "$dir/home/state/.endpoint-binding-migration-v1" \
    || fail 'crash recovery left a stale completion marker'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'crash recovery left a stale journal'
  pass 'crash recovery restores report and marker snapshots'
}

test_no_stamp_crash_restores_evidence_before_rerun() {
  local dir out rc real_mv original_report original_scan original_marker
  dir=$(make_case no-stamp-crash-evidence)
  real_mv=$(command -v mv)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
if [ -n "${FM_FAIL_DEST:-}" ] \
  && [ "${destination##*/}" = "${FM_FAIL_DEST##*/}" ]; then
  exit 1
fi
"${FM_REAL_MV:?}" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ -n "${FM_KILL_DEST:-}" ] \
  && [ "${destination##*/}" = "${FM_KILL_DEST##*/}" ]; then
  kill -KILL "${FM_MIGRATE_PID:?}"
fi
exit "$rc"
SH
  chmod +x "$dir/fakebin/mv"
  printf 'old report\n' > "$dir/home/state/.endpoint-binding-migration.log"
  printf 'old scan\n' > "$dir/home/state/.endpoint-binding-migration-scan-v1"
  printf 'old marker\n' > "$dir/home/state/.endpoint-binding-migration-v1"
  chmod 0644 "$dir/home/state/.endpoint-binding-migration.log" \
    "$dir/home/state/.endpoint-binding-migration-scan-v1" \
    "$dir/home/state/.endpoint-binding-migration-v1"
  original_report=$(mktemp "$dir/report.XXXXXX")
  original_scan=$(mktemp "$dir/scan.XXXXXX")
  original_marker=$(mktemp "$dir/marker.XXXXXX")
  cp "$dir/home/state/.endpoint-binding-migration.log" "$original_report"
  cp "$dir/home/state/.endpoint-binding-migration-scan-v1" "$original_scan"
  cp "$dir/home/state/.endpoint-binding-migration-v1" "$original_marker"
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_KILL_DEST="$dir/home/state/.endpoint-binding-migration-scan-v1" \
    run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "no-stamp evidence crash unexpectedly succeeded: $out"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_FAIL_DEST="$dir/home/state/good.meta" run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "post-recovery stamp failure unexpectedly succeeded: $out"
  cmp -s "$original_report" "$dir/home/state/.endpoint-binding-migration.log" \
    || fail 'no-stamp crash recovery retained a partial report'
  cmp -s "$original_scan" "$dir/home/state/.endpoint-binding-migration-scan-v1" \
    || fail 'no-stamp crash recovery retained a partial scan marker'
  cmp -s "$original_marker" "$dir/home/state/.endpoint-binding-migration-v1" \
    || fail 'no-stamp crash recovery retained a partial completion marker'
  pass 'no-stamp crash recovery privatizes and restores evidence before rerun'
}

test_partial_apply_recovery_tolerates_lifecycle_changes() {
  local dir out stage backup expected
  dir=$(make_case partial-lifecycle-recovery)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  fm_write_meta "$dir/home/state/good2.meta" \
    'window=firstmate:fm-good2' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  stage="$dir/home/state/.endpoint-binding-stage.partial-lifecycle"
  backup="$dir/home/state/.endpoint-binding-migration-backups"
  mkdir "$stage" "$backup"
  chmod 0700 "$stage" "$backup"
  cp "$dir/home/state/good.meta" "$stage/good.before"
  cp "$dir/home/state/good.meta" "$stage/good.after"
  printf 'endpoint_task_id=good\n' >> "$stage/good.after"
  cp "$dir/home/state/good2.meta" "$stage/good2.before"
  cp "$dir/home/state/good2.meta" "$stage/good2.after"
  printf 'endpoint_task_id=good2\n' >> "$stage/good2.after"
  printf '%s\n' $'good\tgood.before\tgood.after' $'good2\tgood2.before\tgood2.after' \
    > "$stage/records"
  cp "$stage/good.before" "$backup/good.before"
  cp "$stage/good.after" "$backup/good.after"
  cp "$stage/good2.before" "$backup/good2.before"
  cp "$stage/good2.after" "$backup/good2.after"
  cp "$stage/records" "$dir/home/state/.endpoint-binding-migration-records-v1"
  chmod 0600 "$stage"/* "$backup"/* \
    "$dir/home/state/.endpoint-binding-migration-records-v1"
  cp "$stage/good.after" "$dir/home/state/good.meta"
  printf 'control_relaunch_tx=x-link-followup\n' >> "$dir/home/state/good.meta"
  expected=$(mktemp "$dir/expected.XXXXXX")
  cp "$stage/good.before" "$expected"
  printf 'control_relaunch_tx=x-link-followup\n' >> "$expected"
  rm -f "$dir/home/state/good2.meta"

  out=$(run_locked "$dir") || fail "partial lifecycle recovery failed: $out"
  assert_contains "$out" 'stamped 1' 'partial lifecycle recovery did not rerun the full scan'
  [ ! -e "$dir/home/state/good2.meta" ] \
    || fail 'partial recovery recreated teardown-deleted metadata'
  out=$(run_locked "$dir" --undo) || fail "partial lifecycle recovery undo failed: $out"
  cmp -s "$expected" "$dir/home/state/good.meta" \
    || fail 'partial recovery did not preserve lifecycle-appended metadata'
  [ ! -e "$dir/home/state/good2.meta" ] \
    || fail 'partial recovery undo recreated deleted metadata'
  pass 'partial apply recovery reconciles lifecycle rewrites and deletions'
}

test_partial_published_journal_reruns_apply() {
  local dir out rc real_mv
  dir=$(make_case partial-published-journal)
  real_mv=$(command -v mv)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
"${FM_REAL_MV:?}" "$@"
rc=$?
if [ "$rc" -eq 0 ] \
  && [ "${destination##*/}" = "${FM_CRASH_DEST##*/}" ]; then
  kill -KILL "${FM_MIGRATE_PID:?}"
fi
exit "$rc"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  set +e
  out=$(FM_REAL_MV="$real_mv" \
    FM_CRASH_DEST="$dir/home/state/.endpoint-binding-migration-records-v1" run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "partial journal publication unexpectedly succeeded: $out"
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'partial journal publication stamped metadata before restart'
  [ -f "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'partial journal publication lost the journal'
  rm -f "$dir/fakebin/mv"
  out=$(run_locked "$dir") || fail "partial journal restart failed: $out"
  assert_contains "$out" 'stamped 1' 'partial journal restart skipped the eligible record'
  assert_contains "$(cat "$dir/home/state/good.meta")" 'endpoint_task_id=good' \
    'partial journal restart did not restore the stamp path'
  out=$(run_locked "$dir" --undo) || fail "partial journal undo failed: $out"
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'partial journal restart was not reversible'
  pass 'endpoint binding migration reruns after partial journal publication'
}

test_partial_merged_journal_reruns_apply() {
  local dir out old_records stage expected
  dir=$(make_case partial-merged-journal)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  run_locked "$dir" >/dev/null || fail 'initial migration for partial merge failed'
  old_records=$(mktemp "$dir/old-records.XXXXXX")
  cp "$dir/home/state/.endpoint-binding-migration-records-v1" "$old_records"
  fm_write_meta "$dir/home/state/good2.meta" \
    'window=firstmate:fm-good2' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  stage="$dir/home/state/.endpoint-binding-stage.partial-merge"
  mkdir "$stage"
  chmod 0700 "$stage"
  cp "$old_records" "$stage/records.before"
  printf '%s\n' $'good2\tgood2.before\tgood2.after' > "$stage/records"
  cp "$dir/home/state/good2.meta" "$stage/good2.before"
  cp "$dir/home/state/good2.meta" "$stage/good2.after"
  printf 'endpoint_task_id=good2\n' >> "$stage/good2.after"
  chmod 0600 "$stage"/*
  cp "$old_records" "$dir/home/state/.endpoint-binding-migration-records-v1"
  printf '%s\n' $'good2\tgood2.before\tgood2.after' >> \
    "$dir/home/state/.endpoint-binding-migration-records-v1"
  cp "$stage/good2.before" \
    "$dir/home/state/.endpoint-binding-migration-backups/good2.before"
  cp "$stage/good2.after" \
    "$dir/home/state/.endpoint-binding-migration-backups/good2.after"
  chmod 0600 "$dir/home/state/.endpoint-binding-migration-backups/good2.before" \
    "$dir/home/state/.endpoint-binding-migration-backups/good2.after"
  cp "$stage/good2.after" "$dir/home/state/good2.meta"
  printf 'control_relaunch_tx=merged-followup\n' >> "$dir/home/state/good2.meta"
  expected=$(mktemp "$dir/good2-expected.XXXXXX")
  cp "$stage/good2.before" "$expected"
  printf 'control_relaunch_tx=merged-followup\n' >> "$expected"
  out=$(run_locked "$dir") || fail "partial merged journal restart failed: $out"
  assert_contains "$out" 'stamped 1' 'partial merged journal restart skipped the eligible record'
  assert_contains "$(cat "$dir/home/state/good2.meta")" 'endpoint_task_id=good2' \
    'partial merged journal restart did not rerun the stamp'
  grep -q $'^good\t' "$dir/home/state/.endpoint-binding-migration-records-v1" \
    || fail 'partial merged journal rollback did not preserve old provenance'
  out=$(run_locked "$dir" --undo) || fail "partial merged journal undo failed: $out"
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'partial merged journal undo did not restore old metadata'
  cmp -s "$expected" "$dir/home/state/good2.meta" \
    || fail 'partial merged journal undo did not preserve lifecycle metadata'
  pass 'endpoint binding migration reruns after partial merged journal publication'
}

test_existing_journal_pre_manifest_stage_is_discarded() {
  local dir out stage
  dir=$(make_case pre-manifest-merge)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  run_locked "$dir" >/dev/null || fail 'initial migration for pre-manifest stage failed'
  fm_write_meta "$dir/home/state/good2.meta" \
    'window=firstmate:fm-good2' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  stage="$dir/home/state/.endpoint-binding-stage.pre-manifest"
  mkdir "$stage"
  chmod 0700 "$stage"
  printf '%s\n' $'good2\tgood2.before\tgood2.after' > "$stage/records"
  chmod 0600 "$stage/records"
  out=$(run_locked "$dir") || fail "pre-manifest stage restart failed: $out"
  assert_contains "$out" 'stamped 1' 'pre-manifest stage restart skipped the eligible record'
  assert_contains "$(cat "$dir/home/state/good2.meta")" 'endpoint_task_id=good2' \
    'pre-manifest stage restart did not rerun the stamp'
  [ ! -e "$stage" ] || fail 'pre-manifest stage was not discarded'
  pass 'endpoint binding migration discards an interrupted existing-journal pre-manifest stage'
}

test_apply_stage_symlink_is_not_followed() {
  local dir out rc outside stage
  dir=$(make_case symlinked-apply-stage)
  outside="$dir/outside-stage"
  stage="$dir/home/state/.endpoint-binding-stage.injected"
  mkdir "$outside"
  printf 'keep\n' > "$outside/sentinel"
  ln -s "$outside" "$stage"
  set +e
  out=$(run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "symlinked apply stage unexpectedly succeeded: $out"
  [ -L "$stage" ] || fail 'symlinked apply stage was removed'
  grep -qx 'keep' "$outside/sentinel" || fail 'symlinked apply stage touched outside data'
  pass 'endpoint binding migration rejects symlinked apply stages without traversal'
}

test_orphaned_backups_are_recovered_on_restart() {
  local dir out stage
  dir=$(make_case orphaned-backups)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  stage="$dir/home/state/.endpoint-binding-stage.injected"
  mkdir "$stage"
  chmod 0700 "$stage"
  printf '%s\n' $'good\tgood.before\tgood.after' > "$stage/records"
  cp "$dir/home/state/good.meta" "$stage/good.before"
  cp "$dir/home/state/good.meta" "$stage/good.after"
  mkdir "$dir/home/state/.endpoint-binding-migration-backups"
  chmod 0700 "$dir/home/state/.endpoint-binding-migration-backups"
  cp "$stage/good.before" "$dir/home/state/.endpoint-binding-migration-backups/good.before"
  cp "$stage/good.after" "$dir/home/state/.endpoint-binding-migration-backups/good.after"
  chmod 0600 "$stage"/* \
    "$dir/home/state/.endpoint-binding-migration-backups"/*
  [ -f "$dir/home/state/.endpoint-binding-migration-backups/good.after" ] \
    || fail 'orphaned backup crash did not leave the interrupted backup'
  out=$(run_locked "$dir") || fail "restart did not recover orphaned backups: $out"
  assert_contains "$out" 'stamped 1' 'restart did not resume migration after orphan cleanup'
  pass 'endpoint binding migration recovers orphaned backups on restart'
}

test_no_stamp_validates_existing_recovery_namespace() {
  local dir out rc
  dir=$(make_case no-stamp-recovery)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' 'endpoint_task_id=good' \
    "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  printf '%s\n' $'good\tgood.before\tgood.after' > \
    "$dir/home/state/.endpoint-binding-migration-records-v1"
  chmod 0644 "$dir/home/state/.endpoint-binding-migration-records-v1"
  mkdir "$dir/home/state/.endpoint-binding-migration-backups"
  chmod 0700 "$dir/home/state/.endpoint-binding-migration-backups"
  set +e
  out=$(run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unsafe recovery namespace was accepted: $out"
  [ ! -e "$dir/home/state/.endpoint-binding-migration-scan-v1" ] \
    || fail 'unsafe recovery namespace published a scan marker'
  pass 'endpoint binding migration validates recovery evidence on no-stamp scans'
}

test_journal_cleanup_failure_retains_recovery_bytes() {
  local dir original out rc real_mv real_rm
  dir=$(make_case journal-cleanup-failure)
  real_mv=$(command -v mv)
  real_rm=$(command -v rm)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
if [ "${destination##*/}" = "${FM_FAIL_DEST##*/}" ]; then exit 1; fi
exec "${FM_REAL_MV:?}" "$@"
SH
  cat > "$dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
fail_target=${FM_FAIL_RM:-}
fail_target=${fail_target##*/}
for arg in "$@"; do
  [ "$arg" = "${FM_FAIL_RM:-}" ] || [ "${arg##*/}" = "$fail_target" ] && exit 1
done
exec "${FM_REAL_RM:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv" "$dir/fakebin/rm"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  original=$(mktemp "$dir/original.XXXXXX")
  cp "$dir/home/state/good.meta" "$original"
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_REAL_RM="$real_rm" \
    FM_FAIL_DEST="$dir/home/state/.endpoint-binding-migration-scan-v1" \
    FM_FAIL_RM="$dir/home/state/.endpoint-binding-migration-records-v1" run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "journal cleanup failure unexpectedly succeeded: $out"
  cmp -s "$original" "$dir/home/state/good.meta" || fail 'journal cleanup failure left stamped metadata'
  [ -f "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'journal cleanup failure discarded the recovery journal'
  [ -f "$dir/home/state/.endpoint-binding-migration-backups/good.before" ] \
    || fail 'journal cleanup failure discarded before recovery bytes'
  [ -f "$dir/home/state/.endpoint-binding-migration-backups/good.after" ] \
    || fail 'journal cleanup failure discarded after recovery bytes'
  pass 'endpoint binding rollback retains recovery bytes when journal cleanup fails'
}

test_recovery_evidence_requires_private_modes() {
  local dir out rc
  dir=$(make_case recovery-modes)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  run_locked "$dir" >/dev/null || fail 'migration setup for recovery mode test failed'
  chmod 0644 "$dir/home/state/.endpoint-binding-migration-records-v1"
  set +e
  out=$(run_locked "$dir" --undo)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "undo accepted a non-private journal: $out"
  chmod 0600 "$dir/home/state/.endpoint-binding-migration-records-v1"
  chmod 0755 "$dir/home/state/.endpoint-binding-migration-backups"
  set +e
  out=$(run_locked "$dir" --undo)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "undo accepted a non-private backup directory: $out"
  chmod 0700 "$dir/home/state/.endpoint-binding-migration-backups"
  out=$(run_locked "$dir" --undo) || fail "undo failed after restoring private modes: $out"
  pass 'endpoint binding migration requires private journal and backup evidence'
}

test_manifest_assembly_rejects_replaced_temporary() {
  local dir original out rc real_mv outside activated
  dir=$(make_case manifest-temporary-race)
  real_mv=$(command -v mv)
  outside="$dir/outside-manifest"
  activated="$dir/manifest-race-activated"
  printf 'keep\n' > "$outside"
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
case "${destination##*/}" in
  .endpoint-binding-records.*)
    rm -f -- "$destination" || exit 1
    ln -s "${FM_OUTSIDE:?}" "$destination" || exit 1
    : > "${FM_RACE_ACTIVATED:?}"
    exit 1
    ;;
esac
exec "${FM_REAL_MV:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  original=$(mktemp "$dir/original.XXXXXX")
  cp "$dir/home/state/good.meta" "$original"
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_OUTSIDE="$outside" FM_RACE_ACTIVATED="$activated" \
    run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "manifest temporary replacement unexpectedly succeeded: $out"
  [ -f "$activated" ] || fail 'manifest temporary race fixture did not activate'
  [ "$(cat "$outside")" = keep ] || fail 'manifest assembly wrote through a replaced temporary'
  cmp -s "$original" "$dir/home/state/good.meta" \
    || fail 'manifest temporary replacement left stamped metadata'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'manifest temporary replacement published a stamp journal'
  pass 'endpoint binding migration rejects replaced manifest temporaries'
}

test_undo_cleanup_failure_retains_recovery_evidence() {
  local dir out rc real_rm failed_backup
  dir=$(make_case undo-cleanup-failure)
  real_rm=$(command -v rm)
  cat > "$dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    -f|--) ;;
    *)
      if [ "$arg" = "${FM_FAIL_RM:-}" ]; then exit 1; fi
      if [ "${arg##*/}" = "${FM_FAIL_RM##*/}" ]; then exit 1; fi
      "${FM_REAL_RM:?}" -f -- "$arg" || exit 1
      ;;
  esac
done
SH
  chmod +x "$dir/fakebin/rm"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  FM_REAL_RM="$real_rm" run_locked "$dir" >/dev/null \
    || fail 'migration setup for cleanup failure test failed'
  failed_backup="$dir/home/state/.endpoint-binding-migration-backups/good.after"
  set +e
  out=$(FM_REAL_RM="$real_rm" FM_FAIL_RM="$failed_backup" run_locked "$dir" --undo)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "undo cleanup failure unexpectedly succeeded: $out"
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'undo cleanup failure did not restore metadata'
  [ -f "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'undo cleanup failure discarded the journal'
  [ -f "$failed_backup" ] || fail 'undo cleanup failure discarded recovery evidence'
  out=$(FM_REAL_RM="$real_rm" run_locked "$dir" --undo) \
    || fail "undo retry after cleanup failure failed: $out"
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'undo retry left the journal'
  pass 'endpoint binding undo reports cleanup failures and retains recovery evidence'
}

test_undo_recovery_stage_is_retained_when_restore_fails() {
  local dir out rc real_rm real_mv stage
  dir=$(make_case undo-stage-failure)
  real_rm=$(command -v rm)
  real_mv=$(command -v mv)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
if [ "${FM_FAIL_COPY_AFTER:-0}" -eq 1 ] \
  && [ "${destination##*/}" = good.after ]; then
  case "$PWD" in
    */.endpoint-binding-migration-backups) exit 1 ;;
  esac
fi
exec "${FM_REAL_MV:?}" "$@"
SH
  cat > "$dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
fail_target=${FM_FAIL_RM:-}
fail_target=${fail_target##*/}
for arg in "$@"; do
  [ "$arg" = "${FM_FAIL_RM:-}" ] || [ "${arg##*/}" = "$fail_target" ] && exit 1
done
  exec "${FM_REAL_RM:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv" "$dir/fakebin/rm"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  FM_REAL_RM="$real_rm" FM_REAL_MV="$real_mv" run_locked "$dir" >/dev/null \
    || fail 'migration setup for undo stage failure test failed'
  set +e
  out=$(FM_REAL_RM="$real_rm" FM_REAL_MV="$real_mv" \
    FM_FAIL_RM="$dir/home/state/.endpoint-binding-migration-records-v1" \
    FM_FAIL_COPY_AFTER=1 run_locked "$dir" --undo)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "undo stage failure unexpectedly succeeded: $out"
  stage=$(find "$dir/home/state" -maxdepth 1 -type d -name '.endpoint-binding-undo-cleanup.*' -print -quit)
  [ -n "$stage" ] || fail 'undo stage failure discarded recovery staging'
  [ -f "$stage/records" ] || fail 'undo stage failure discarded staged journal'
  pass 'endpoint binding undo retains recovery staging when restoration fails'
}

test_undo_stage_cleanup_failure_retains_completion_state() {
  local dir out rc real_rm stage
  dir=$(make_case undo-stage-cleanup)
  real_rm=$(command -v rm)
cat > "$dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    ./completed)
      case "$(pwd)" in
        */.endpoint-binding-undo-cleanup.*) exit 1 ;;
      esac
      ;;
  esac
done
exec "${FM_REAL_RM:?}" "$@"
SH
  chmod +x "$dir/fakebin/rm"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  FM_REAL_RM="$real_rm" run_locked "$dir" >/dev/null \
    || fail 'migration setup for stage cleanup test failed'
  set +e
  out=$(FM_REAL_RM="$real_rm" run_locked "$dir" --undo)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "undo stage cleanup failure unexpectedly succeeded: $out"
  stage=$(find "$dir/home/state" -maxdepth 1 -type d -name '.endpoint-binding-undo-cleanup.*' -print -quit)
  [ -n "$stage" ] || fail 'undo stage cleanup failure discarded staging'
  [ -f "$stage/completed" ] || fail 'undo stage cleanup failure lost completion state'
  rm -f "$dir/fakebin/rm"
  out=$(FM_REAL_RM="$real_rm" run_locked "$dir" --undo) \
    || fail "undo retry after stage cleanup failure failed: $out"
  [ ! -e "$stage" ] || fail 'undo retry did not clean completed staging'
  pass 'endpoint binding undo retains completion state when stage cleanup fails'
}

test_incomplete_rollback_retains_recovery_evidence() {
  local dir original out rc real_mv stage
  dir=$(make_case rollback-failure)
  real_mv=$(command -v mv)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
if [ -n "${FM_FAIL_DEST:-}" ] \
  && [ "${destination##*/}" = "${FM_FAIL_DEST##*/}" ]; then exit 1; fi
if [ "${destination##*/}" = "${FM_META_DEST##*/}" ] \
  && [ "$PWD" = "${FM_META_DEST%/*}" ] && [ "${FM_FAIL_ROLLBACK:-0}" -eq 1 ] \
  && [ -e "${FM_META_MOVED:?}" ]; then
  exit 1
fi
"${FM_REAL_MV:?}" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ "${destination##*/}" = "${FM_META_DEST##*/}" ] \
  && [ "$PWD" = "${FM_META_DEST%/*}" ]; then : > "$FM_META_MOVED"; fi
exit "$rc"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  original=$(mktemp "$dir/original.XXXXXX")
  cp "$dir/home/state/good.meta" "$original"
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_FAIL_DEST="$dir/home/state/.endpoint-binding-migration-scan-v1" \
    FM_FAIL_ROLLBACK=1 FM_META_DEST="$dir/home/state/good.meta" \
    FM_META_MOVED="$dir/meta-moved" run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "rollback failure unexpectedly succeeded: $out"
  assert_contains "$(cat "$dir/home/state/good.meta")" 'endpoint_task_id=good' \
    'rollback failure unexpectedly discarded the stamped metadata'
  [ -f "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'rollback failure discarded the recovery journal'
  [ -d "$dir/home/state/.endpoint-binding-migration-backups" ] \
    || fail 'rollback failure discarded recovery backups'
  stage=$(find "$dir/home/state" -maxdepth 1 -type d -name '.endpoint-binding-stage.*' -print -quit)
  [ -n "$stage" ] || fail 'rollback failure discarded staged recovery evidence'
  out=$(FM_REAL_MV="$real_mv" FM_META_DEST="$dir/home/state/good.meta" \
    FM_META_MOVED="$dir/meta-moved" run_locked "$dir" --undo) \
    || fail "recovery journal undo failed: $out"
  cmp -s "$original" "$dir/home/state/good.meta" || fail 'recovery undo did not restore prior metadata'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'recovery undo left the journal'
  pass 'endpoint binding migration retains an undo path after incomplete rollback'
}

test_evidence_bound_stamp_and_skip
test_shared_validator_refusal_reason_is_reported
test_unreadable_metadata_is_reported
test_vanished_metadata_is_reported
test_duplicate_tmux_window_is_ambiguous
test_tmux_session_prefix_is_not_an_exact_endpoint
test_tmux_name_reuse_requires_recorded_worktree
test_tmux_liveness_is_rechecked_after_worktree_read
test_live_legacy_herdr_endpoint_is_backfilled
test_herdr_liveness_is_rechecked_without_server_ensure
test_staged_binding_assembly_does_not_follow_symlinks
test_unresolved_existing_bindings_remove_completion_marker
test_stamp_adds_binding_as_separate_line_without_trailing_newline
test_hidden_metadata_is_reported
test_completed_journal_is_idempotent
test_completed_journal_merges_new_record
test_completed_journal_recovers_orphaned_merge_backups
test_merge_abort_restores_manifest_before_backup_cleanup
test_undo_preserves_lifecycle_appends
test_undo_skips_relaunch_owned_matching_binding
test_undo_skips_deleted_and_changed_bindings
test_incomplete_apply_stage_is_cleaned_on_restart
test_partial_recovery_rollback_artifact_is_restart_cleanable
test_completed_apply_stage_survives_cleanup_failure
test_completed_journal_refuses_unexpected_record
test_completed_journal_refuses_dangling_backup_entry
test_undo_recovery_rejects_symlink_destination
test_private_atomic_publication_does_not_follow_destination_symlink
test_journal_publication_does_not_follow_destination_symlink
test_evidence_publication_does_not_follow_destination_symlinks
test_migration_does_not_require_perl
test_undo_recovery_rejects_symlink_stage
test_undo_snapshot_copy_is_atomic
test_undo_snapshot_rejects_replaced_stage_parent
test_existing_records_snapshot_is_atomic
test_final_live_recheck_refuses_dead_endpoint
test_final_metadata_change_reruns_scan
test_reverse_restores_prior_bytes
test_shared_task_id_grammar_reports_colon_ids
test_lock_is_required
test_symlink_session_lock_is_refused
test_session_lock_symlink_swap_is_refused
test_expired_session_lock_after_wait_is_refused
test_signal_rolls_back_staged_stamps
test_final_stamp_waits_for_metadata_lock
test_migration_transaction_lock_serializes_no_stamp_runs
test_stamp_lock_is_held_through_publication_rollback
test_undo_waits_for_metadata_lock
test_undo_signal_restores_stamped_bytes
test_crashed_undo_restores_current_snapshot_before_apply
test_undo_signal_during_cleanup_restores_recovery_state
test_identity_verification_waits_for_metadata_lock
test_report_write_failure_aborts_before_stamping
test_publication_failure_restores_evidence
test_abort_interruption_retains_recovery_stage
test_backup_cleanup_failure_retains_staged_recovery
test_rollback_rejects_replaced_backup_directory_symlink
test_recovery_journal_copy_is_atomic
test_crash_after_manifest_preserves_undo_path
test_crash_recovery_restores_evidence_snapshots
test_no_stamp_crash_restores_evidence_before_rerun
test_partial_apply_recovery_tolerates_lifecycle_changes
test_partial_published_journal_reruns_apply
test_partial_merged_journal_reruns_apply
test_existing_journal_pre_manifest_stage_is_discarded
test_apply_stage_symlink_is_not_followed
test_orphaned_backups_are_recovered_on_restart
test_no_stamp_validates_existing_recovery_namespace
test_journal_cleanup_failure_retains_recovery_bytes
test_recovery_evidence_requires_private_modes
test_manifest_assembly_rejects_replaced_temporary
test_undo_cleanup_failure_retains_recovery_evidence
test_undo_recovery_stage_is_retained_when_restore_fails
test_undo_stage_cleanup_failure_retains_completion_state
test_incomplete_rollback_retains_recovery_evidence
