#!/usr/bin/env bash
# Regression tests for the locked, evidence-bound legacy endpoint binding
# migration and its reversible stamped-record journal.
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
    for name in ${!FM_@}; do export "$name"; done
    export FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_LOCK_PID="$owner"
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
  assert_contains "$report" 'task mismatch: skipped - identity mismatch' 'identity mismatch was not reported'
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
  local dir out report
  dir=$(make_case hidden-meta)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  fm_write_meta "$dir/home/state/.legacy.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  fm_write_meta "$dir/home/state/.meta" \
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
  ! grep -q '^endpoint_task_id=' "$dir/home/state/.legacy.meta" \
    || fail 'hidden metadata was stamped'
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

test_completed_journal_refuses_changed_metadata() {
  local dir out rc
  dir=$(make_case completed-journal-changed)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  run_locked "$dir" >/dev/null || fail 'initial migration for changed journal failed'
  printf '%s\n' changed >> "$dir/home/state/good.meta"
  set +e
  out=$(run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "changed journal metadata was accepted: $out"
  pass 'endpoint binding migration validates completed journal metadata bytes'
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
  local dir out rc real_cp stage
  dir=$(make_case undo-snapshot-copy)
  real_cp=$(command -v cp)
  cat > "$dir/fakebin/cp" <<'SH'
#!/usr/bin/env bash
dest=${!#}
if [ "${FM_FAIL_COPY:-0}" -eq 1 ]; then
  case "$dest" in
    */.endpoint-binding-copy.*) : > "$dest"; exit 1 ;;
  esac
fi
exec "${FM_REAL_CP:?}" "$@"
SH
  chmod +x "$dir/fakebin/cp"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  FM_REAL_CP="$real_cp" run_locked "$dir" >/dev/null \
    || fail 'migration setup for undo snapshot copy failed'
  set +e
  out=$(FM_REAL_CP="$real_cp" FM_FAIL_COPY=1 run_locked "$dir" --undo)
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
  pass 'endpoint binding undo stages snapshots atomically'
}

test_existing_records_snapshot_is_atomic() {
  local dir out rc records_before
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
  cat > "$dir/fakebin/cp" <<'SH'
#!/usr/bin/env bash
dest=${!#}
case "$dest" in
  */records.before.*) : > "$dest"; exit 1 ;;
esac
exec /bin/cp "$@"
SH
  chmod +x "$dir/fakebin/cp"
  set +e
  out=$(run_locked "$dir")
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
  [ "$rc" -ne 0 ] || fail "dead final endpoint unexpectedly migrated: $out"
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'dead final endpoint was stamped'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'dead final endpoint left a journal'
  pass 'endpoint binding migration rechecks live identity immediately before replacement'
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

test_signal_rolls_back_staged_stamps() {
  local dir original out rc real_mv
  dir=$(make_case signal)
  real_mv=$(command -v mv)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
"${FM_REAL_MV:?}" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ "${4:-}" = "${FM_SIGNAL_META:?}" ] \
  && [ ! -e "${FM_SIGNAL_SENT_FILE:?}" ]; then
  : > "$FM_SIGNAL_SENT_FILE"
  kill -TERM "$PPID"
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
  local dir original out rc real_chmod
  dir=$(make_case report-write-failure)
  real_chmod=$(command -v chmod)
  cat > "$dir/fakebin/chmod" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */report.*)
      rm -f -- "$arg"
      mkdir -- "$arg"
      exit 0
      ;;
  esac
done
exec "${FM_REAL_CHMOD:?}" "$@"
SH
  chmod +x "$dir/fakebin/chmod"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  original=$(mktemp "$dir/original.XXXXXX")
  cp "$dir/home/state/good.meta" "$original"
  set +e
  out=$(FM_REAL_CHMOD="$real_chmod" run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "report write failure unexpectedly succeeded: $out"
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
"${FM_REAL_MV:?}" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ -n "${FM_UNDO_SIGNAL_META:-}" ] \
  && [ "${4:-}" = "$FM_UNDO_SIGNAL_META" ] \
  && [ "${FM_UNDO_SIGNAL:-0}" -eq 1 ] && [ ! -e "${FM_UNDO_SIGNAL_SENT:?}" ]; then
  : > "$FM_UNDO_SIGNAL_SENT"
  kill -TERM "$PPID"
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
      kill -TERM "$PPID"
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
  local dir original out rc real_mv
  dir=$(make_case publication-failure)
  real_mv=$(command -v mv)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAIL_DEST:-}" ] && [ "${4:-}" = "$FM_FAIL_DEST" ]; then exit 1; fi
exec "${FM_REAL_MV:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  original=$(mktemp "$dir/original.XXXXXX")
  cp "$dir/home/state/good.meta" "$original"
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_FAIL_DEST="$dir/home/state/.endpoint-binding-migration-scan-v1" \
    run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "publication failure unexpectedly succeeded: $out"
  cmp -s "$original" "$dir/home/state/good.meta" || fail 'publication failure left stamped metadata'
  [ ! -e "$dir/home/state/.endpoint-binding-migration.log" ] \
    || fail 'publication failure left a stale report'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-scan-v1" ] \
    || fail 'publication failure left a stale scan marker'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-v1" ] \
    || fail 'publication failure left a stale completion marker'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'publication failure left a stale stamp journal'
  pass 'endpoint binding migration rolls back published evidence on failure'
}

test_backup_cleanup_failure_retains_staged_recovery() {
  local dir out rc real_mv real_rm stage
  dir=$(make_case backup-cleanup-failure)
  real_mv=$(command -v mv)
  real_rm=$(command -v rm)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
if [ "${4:-}" = "${FM_FAIL_DEST:-}" ]; then exit 1; fi
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
if [ "${4:-}" = "${FM_FAIL_DEST:-}" ]; then
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
  local dir out rc real_cp stage
  dir=$(make_case recovery-journal-copy)
  real_cp=$(command -v cp)
  cat > "$dir/fakebin/cp" <<'SH'
#!/usr/bin/env bash
dest=${!#}
if [ "${FM_FAIL_COPY:-0}" -eq 1 ]; then
  case "$dest" in
    */.endpoint-binding-copy.*) : > "$dest"; exit 1 ;;
  esac
fi
exec "${FM_REAL_CP:?}" "$@"
SH
  chmod +x "$dir/fakebin/cp"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  FM_REAL_CP="$real_cp" run_locked "$dir" >/dev/null \
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
  out=$(FM_REAL_CP="$real_cp" FM_FAIL_COPY=1 run_locked "$dir" --undo)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "partial recovery journal copy unexpectedly succeeded: $out"
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'partial recovery copy published a truncated journal'
  pass 'endpoint binding recovery stages journal copies atomically'
}

test_crash_after_manifest_preserves_undo_path() {
  local dir out rc real_mv
  dir=$(make_case crash-before-stamp)
  real_mv=$(command -v mv)
cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" = "${FM_CRASH_DEST:-}" ] || continue
  "${FM_REAL_MV:?}" "$@"
  kill -KILL "$PPID"
  exit 137
done
exec "${FM_REAL_MV:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_CRASH_DEST="$dir/home/state/.endpoint-binding-migration-records-v1" run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "manifest crash unexpectedly succeeded: $out"
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'manifest crash left metadata stamped without an apply'
  [ -f "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'manifest crash discarded the durable journal'
  [ -f "$dir/home/state/.endpoint-binding-migration-backups/good.before" ] \
    || fail 'manifest crash discarded before recovery bytes'
  out=$(FM_REAL_MV="$real_mv" run_locked "$dir" --undo) \
    || fail "manifest crash recovery undo failed: $out"
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'manifest crash recovery left the journal'
  pass 'endpoint binding migration publishes recovery state before stamping'
}

test_partial_published_journal_reruns_apply() {
  local dir out rc real_mv
  dir=$(make_case partial-published-journal)
  real_mv=$(command -v mv)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
"${FM_REAL_MV:?}" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ "${4:-}" = "${FM_CRASH_DEST:-}" ]; then
  kill -KILL "$PPID"
fi
exit "$rc"
SH
  chmod +x "$dir/fakebin/mv"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  set +e
  out=$(FM_REAL_MV="$real_mv" FM_CRASH_DEST="$dir/home/state/.endpoint-binding-migration-records-v1" run_locked "$dir")
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
  local dir out old_records stage
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
  out=$(run_locked "$dir") || fail "partial merged journal restart failed: $out"
  assert_contains "$out" 'stamped 1' 'partial merged journal restart skipped the eligible record'
  assert_contains "$(cat "$dir/home/state/good2.meta")" 'endpoint_task_id=good2' \
    'partial merged journal restart did not rerun the stamp'
  grep -q $'^good\t' "$dir/home/state/.endpoint-binding-migration-records-v1" \
    || fail 'partial merged journal rollback did not preserve old provenance'
  out=$(run_locked "$dir" --undo) || fail "partial merged journal undo failed: $out"
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'partial merged journal undo did not restore old metadata'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good2.meta" \
    || fail 'partial merged journal undo did not restore new metadata'
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
if [ "${4:-}" = "${FM_FAIL_DEST:-}" ]; then exit 1; fi
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

test_manifest_mode_failure_rolls_back_stamps() {
  local dir original out rc real_chmod
  dir=$(make_case manifest-mode-failure)
  real_chmod=$(command -v chmod)
cat > "$dir/fakebin/chmod" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.endpoint-binding-records.*) exit 1 ;;
  esac
done
exec "${FM_REAL_CHMOD:?}" "$@"
SH
  chmod +x "$dir/fakebin/chmod"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  original=$(mktemp "$dir/original.XXXXXX")
  cp "$dir/home/state/good.meta" "$original"
  set +e
  out=$(FM_REAL_CHMOD="$real_chmod" run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "manifest mode failure unexpectedly succeeded: $out"
  cmp -s "$original" "$dir/home/state/good.meta" || fail 'manifest mode failure left stamped metadata'
  [ ! -e "$dir/home/state/.endpoint-binding-migration-records-v1" ] \
    || fail 'manifest mode failure published a stamp journal'
  pass 'endpoint binding migration rolls back when journal permissions cannot be secured'
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
  local dir out rc real_rm real_cp stage
  dir=$(make_case undo-stage-failure)
  real_rm=$(command -v rm)
  real_cp=$(command -v cp)
  cat > "$dir/fakebin/cp" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAIL_CP_AFTER:-0}" -eq 1 ]; then
  case "$(pwd):${1:-}:${2:-}:${3:-}" in
    */.endpoint-binding-undo-cleanup.*:*-p*:--:./good.after) exit 1 ;;
  esac
fi
exec "${FM_REAL_CP:?}" "$@"
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
  chmod +x "$dir/fakebin/cp" "$dir/fakebin/rm"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  FM_REAL_RM="$real_rm" FM_REAL_CP="$real_cp" run_locked "$dir" >/dev/null \
    || fail 'migration setup for undo stage failure test failed'
  set +e
  out=$(FM_REAL_RM="$real_rm" FM_REAL_CP="$real_cp" \
    FM_FAIL_RM="$dir/home/state/.endpoint-binding-migration-records-v1" \
    FM_FAIL_CP_AFTER=1 \
    run_locked "$dir" --undo)
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
if [ -n "${FM_FAIL_DEST:-}" ] && [ "${4:-}" = "$FM_FAIL_DEST" ]; then exit 1; fi
if [ "${4:-}" = "${FM_META_DEST:?}" ] && [ "${FM_FAIL_ROLLBACK:-0}" -eq 1 ] \
  && [ -e "${FM_META_MOVED:?}" ]; then
  exit 1
fi
"${FM_REAL_MV:?}" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ "${4:-}" = "$FM_META_DEST" ]; then : > "$FM_META_MOVED"; fi
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
test_stamp_adds_binding_as_separate_line_without_trailing_newline
test_hidden_metadata_is_reported
test_completed_journal_is_idempotent
test_completed_journal_merges_new_record
test_completed_journal_recovers_orphaned_merge_backups
test_completed_journal_refuses_changed_metadata
test_incomplete_apply_stage_is_cleaned_on_restart
test_completed_journal_refuses_unexpected_record
test_completed_journal_refuses_dangling_backup_entry
test_undo_recovery_rejects_symlink_destination
test_undo_recovery_rejects_symlink_stage
test_undo_snapshot_copy_is_atomic
test_existing_records_snapshot_is_atomic
test_final_live_recheck_refuses_dead_endpoint
test_reverse_restores_prior_bytes
test_shared_task_id_grammar_reports_colon_ids
test_lock_is_required
test_signal_rolls_back_staged_stamps
test_final_stamp_waits_for_metadata_lock
test_undo_waits_for_metadata_lock
test_undo_signal_restores_stamped_bytes
test_undo_signal_during_cleanup_restores_recovery_state
test_identity_verification_waits_for_metadata_lock
test_report_write_failure_aborts_before_stamping
test_publication_failure_restores_evidence
test_backup_cleanup_failure_retains_staged_recovery
test_rollback_rejects_replaced_backup_directory_symlink
test_recovery_journal_copy_is_atomic
test_crash_after_manifest_preserves_undo_path
test_partial_published_journal_reruns_apply
test_partial_merged_journal_reruns_apply
test_existing_journal_pre_manifest_stage_is_discarded
test_apply_stage_symlink_is_not_followed
test_orphaned_backups_are_recovered_on_restart
test_no_stamp_validates_existing_recovery_namespace
test_journal_cleanup_failure_retains_recovery_bytes
test_recovery_evidence_requires_private_modes
test_manifest_mode_failure_rolls_back_stamps
test_undo_cleanup_failure_retains_recovery_evidence
test_undo_recovery_stage_is_retained_when_restore_fails
test_undo_stage_cleanup_failure_retains_completion_state
test_incomplete_rollback_retains_recovery_evidence
