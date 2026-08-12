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
  [ "$arg" = "${FM_FAIL_RM:-}" ] && exit 1
done
exec "${FM_REAL_RM:?}" "$@"
SH
  chmod +x "$dir/fakebin/rm"
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" \
    'kind=scout'
  FM_REAL_RM="$real_rm" run_locked "$dir" >/dev/null \
    || fail 'migration setup for cleanup failure test failed'
  failed_backup="$dir/home/state/.endpoint-binding-migration-backups/good.before"
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
test_reverse_restores_prior_bytes
test_lock_is_required
test_signal_rolls_back_staged_stamps
test_final_stamp_waits_for_metadata_lock
test_undo_waits_for_metadata_lock
test_undo_signal_restores_stamped_bytes
test_identity_verification_waits_for_metadata_lock
test_report_write_failure_aborts_before_stamping
test_publication_failure_restores_evidence
test_manifest_mode_failure_rolls_back_stamps
test_undo_cleanup_failure_retains_recovery_evidence
test_incomplete_rollback_retains_recovery_evidence
