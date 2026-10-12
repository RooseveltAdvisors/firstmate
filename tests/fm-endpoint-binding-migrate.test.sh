#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

MIGRATE="$ROOT/bin/fm-endpoint-binding-migrate.sh"
TMP_ROOT=$(fm_test_tmproot fm-endpoint-binding-migrate)
BASE_PATH=$PATH

make_case() {
  local dir=$1 fakebin
  mkdir -p "$TMP_ROOT/$dir/home/state" "$TMP_ROOT/$dir/worktree" \
    "$TMP_ROOT/$dir/project" "$TMP_ROOT/$dir/fakebin"
  fakebin="$TMP_ROOT/$dir/fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$1:$2" in
  -o:comm=|-o:args=)
    [ "$4" = "$FM_LOCK_PID" ] && printf 'pi\n' || printf 'bash\n'
    ;;
  -o:ppid=) printf '1\n' ;;
  -t:*) exit 0 ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "$1" = list-windows ]; then
  if [ "${FM_FAKE_MODE:-}" = refusals ]; then
    printf '%s\n' fm-ambiguous fm-ambiguous fm-unreadable fm-mismatch
  elif [ "${FM_FAKE_MODE:-}" = budget ]; then
    printf '%s\n' fm-good
    for i in $(seq -w 1 20); do printf 'fm-a%s\n' "$i"; done
  elif [ "${FM_FAKE_MODE:-}" = missing ]; then
    printf '%s\n' fm-good
  else
    printf '%s\n' fm-good fm-dead fm-bound
  fi
  exit 0
fi
  if [ "$1" = display-message ]; then
    case "$5" in
    '#{pane_tty}') printf '/dev/null\n' ;;
    '#{pane_current_command}')
      case "$4" in
        '=firstmate:=fm-unreadable'|'=firstmate:=fm-a'*) printf '\n' ;;
        '=firstmate:=fm-good'|'=firstmate:=fm-mismatch'|'=firstmate:=fm-ambiguous') printf 'pi\n' ;;
        *) printf 'bash\n' ;;
      esac
      ;;
    '#{pane_current_path}')
      case "$4" in
        '=firstmate:=fm-unreadable') exit 0 ;;
        '=firstmate:=fm-mismatch') printf '%s\n' "$FM_WRONG_WORKTREE" ;;
        *) printf '%s\n' "$FM_LIVE_WORKTREE" ;;
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
    export FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_LOCK_PID="$owner" FM_MIGRATE_PID="$owner"
    export PATH="$dir/fakebin:$BASE_PATH" FM_LIVE_WORKTREE="$dir/worktree" FM_WRONG_WORKTREE="$dir/project"
    printf '%s\n' "$owner" > "$dir/home/state/.lock"
    exec "$MIGRATE" "$@"
  )
}

test_evidence_bound_scan() {
  local dir out
  dir=$(make_case apply)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  fm_write_meta "$dir/home/state/dead.meta" \
    'window=firstmate:fm-dead' "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  fm_write_meta "$dir/home/state/bound.meta" \
    'window=firstmate:fm-bound' 'endpoint_task_id=bound' \
    "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'

  out=$(run_locked "$dir") || fail "migration failed: $out"
  grep -qx 'endpoint_task_id=good' "$dir/home/state/good.meta" \
    || fail 'live exact endpoint was not stamped'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/dead.meta" \
    || fail 'dead endpoint was stamped'
  grep -qx 'endpoint_task_id=bound' "$dir/home/state/bound.meta" \
    || fail 'existing binding changed'
  ! compgen -G "$dir/home/state/.fm-endpoint-binding-*" >/dev/null \
    || fail 'scan left migration state behind'
  grep -qx 'endpoint_binding_verdict=terminal: dead endpoint' "$dir/home/state/dead.meta" \
    || fail 'dead endpoint verdict was not recorded'
  [ "$out" = 'ENDPOINT_BINDING_MIGRATION: stamped 1; refused 1 (terminal reason recorded as endpoint_binding_verdict in each refused record)' ] \
    || fail "changed scan did not print exactly one summary line: $out"
  pass 'endpoint binding scan stamps only a verified live identity'
}

test_rerun_is_silent_and_never_reprobes_verdicts() {
  local dir out
  dir=$(make_case converge)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  fm_write_meta "$dir/home/state/dead.meta" \
    'window=firstmate:fm-dead' "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  out=$(run_locked "$dir") || fail "first scan failed: $out"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'probed\n' >> "$FM_PROBE_LOG"
exit 1
SH
  out=$(FM_PROBE_LOG="$dir/probe.log" run_locked "$dir") || fail "rerun failed: $out"
  [ -z "$out" ] || fail "unchanged rerun printed output: $out"
  [ ! -e "$dir/probe.log" ] || fail 'rerun probed the backend for records that already carry a verdict'
  grep -qx 'endpoint_binding_verdict=terminal: dead endpoint' "$dir/home/state/dead.meta" \
    || fail 'recorded verdict changed on rerun'
  pass 'a rerun with nothing to change is silent and never re-probes recorded verdicts'
}

test_missing_endpoints_are_terminal_and_free() {
  local dir out i count
  dir=$(make_case missing)
  for i in $(seq -w 1 20); do
    fm_write_meta "$dir/home/state/closed$i.meta" \
      "window=firstmate:fm-closed$i" "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  done
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  out=$(FM_FAKE_MODE=missing run_locked "$dir") || fail "missing scan failed: $out"
  count=$(grep -lx 'endpoint_binding_verdict=terminal: missing endpoint' "$dir"/home/state/closed*.meta | wc -l)
  [ "$count" -eq 20 ] || fail "only $count missing endpoints recorded a terminal verdict"
  grep -qx 'endpoint_task_id=good' "$dir/home/state/good.meta" \
    || fail 'terminal records consumed the probe budget before the live task'
  pass 'missing endpoints are terminal and never consume the per-start probe budget'
}

test_record_shape_refusal_is_terminal() {
  local dir out
  dir=$(make_case shape)
  fm_write_meta "$dir/home/state/shape.meta" \
    'window=firstmate:not-shape' "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  out=$(run_locked "$dir") || fail "shape scan failed: $out"
  grep -q '^endpoint_binding_verdict=terminal: record shape: ' "$dir/home/state/shape.meta" \
    || fail 'record-shape refusal was not recorded as terminal'
  pass 'a record-shape refusal is recorded as a class-named terminal verdict'
}

test_retryable_probes_are_bounded_per_start() {
  local dir out i
  dir=$(make_case budget)
  for i in $(seq -w 1 20); do
    fm_write_meta "$dir/home/state/a$i.meta" \
      "window=firstmate:fm-a$i" "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  done
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  out=$(FM_FAKE_MODE=budget run_locked "$dir") || fail "budget scan failed: $out"
  ! grep -q '^endpoint_binding_verdict=' "$dir"/home/state/a*.meta \
    || fail 'an unreadable endpoint was persisted as terminal'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/good.meta" \
    || fail 'retryable probes were not bounded per start'
  [ -z "$out" ] || fail "retryable-only scan printed output: $out"
  pass 'retryable probes are bounded per start'
}

test_unsupported_backends_are_skipped_before_budget() {
  local dir out i
  dir=$(make_case missing)
  for i in $(seq -w 1 20); do
    fm_write_meta "$dir/home/state/b$i.meta" \
      "window=zellij:$i" 'backend=zellij' 'zellij_session=zellij' 'zellij_tab_id=1' \
      "zellij_pane_id=$i" "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  done
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  out=$(FM_FAKE_MODE=missing run_locked "$dir") || fail "unsupported scan failed: $out"
  ! grep -q '^endpoint_binding_verdict=\|^endpoint_task_id=' "$dir"/home/state/b*.meta \
    || fail 'an unsupported-backend record was stamped or given a verdict'
  grep -qx 'endpoint_task_id=good' "$dir/home/state/good.meta" \
    || fail 'unsupported-backend records consumed the probe budget before the live task'
  pass 'unsupported backends are skipped without a verdict or a probe budget charge'
}

make_herdr_case() {
  local dir
  dir=$(make_case "$1")
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
running() {
  [ "$FM_FAKE_HERDR" = absent ] || [ -e "$FM_HERDR_STARTED" ]
}
case "$1 $2" in
  'server --session')
    touch "$FM_HERDR_SERVER_CALLED"
    [ "$FM_FAKE_HERDR" = nostart ] || touch "$FM_HERDR_STARTED"
    ;;
  'status --json')
    if running; then printf '{"server":{"running":true}}\n'; else printf '{"server":{"running":false}}\n'; fi
    ;;
  'workspace list') printf '{"result":{"workspaces":[]}}\n' ;;
  'pane get')
    if [ "$FM_FAKE_HERDR" = absent ]; then
      printf '{"error":{"code":"pane_not_found"}}\n'
    else
      printf 'connection refused\n' >&2
      exit 1
    fi
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$dir/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exec "$FM_REAL_SLEEP" 0.05
SH
  chmod +x "$dir/fakebin/herdr" "$dir/fakebin/sleep"
  fm_write_meta "$dir/home/state/hd.meta" \
    'backend=herdr' 'window=sess:p1' 'herdr_session=sess' 'herdr_workspace_id=w1' \
    'herdr_tab_id=t1' 'herdr_pane_id=p1' "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  printf '%s\n' "$dir"
}

run_herdr() {
  local dir=$1 mode=$2
  FM_FAKE_HERDR=$mode FM_REAL_SLEEP=$(command -v sleep) FM_HERDR_STARTED="$dir/herdr.started" \
    FM_HERDR_SERVER_CALLED="$dir/herdr.server" run_locked "$dir"
}

test_herdr_absent_pane_is_terminal() {
  local dir out
  dir=$(make_herdr_case herdr-absent)
  out=$(run_herdr "$dir" absent) || fail "herdr absent scan failed: $out"
  grep -qx 'endpoint_binding_verdict=terminal: missing endpoint' "$dir/home/state/hd.meta" \
    || fail 'reachable herdr missing pane was not recorded as terminal'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/hd.meta" || fail 'absent herdr pane was stamped'
  pass 'a herdr pane positively absent on a running server is a terminal missing endpoint'
}

test_herdr_stopped_server_recheck_stays_retryable() {
  local dir out
  dir=$(make_herdr_case herdr-stopped)
  out=$(run_herdr "$dir" restart-unreadable) || fail "herdr stopped scan failed: $out"
  [ -e "$dir/herdr.server" ] || fail 'stopped-server missing was not rechecked with the server running'
  ! grep -q '^endpoint_binding_verdict=\|^endpoint_task_id=' "$dir/home/state/hd.meta" \
    || fail 'a stopped-server missing with an unreadable recheck was persisted'
  [ -z "$out" ] || fail "retryable herdr scan printed output: $out"
  pass 'a stopped-server herdr missing whose recheck is unreadable stays retryable'
}

test_herdr_failed_server_ensure_stays_retryable() {
  local dir out
  dir=$(make_herdr_case herdr-nostart)
  out=$(run_herdr "$dir" nostart) || fail "herdr nostart scan failed: $out"
  [ -e "$dir/herdr.server" ] || fail 'recheck did not try to start the herdr server'
  ! grep -q '^endpoint_binding_verdict=\|^endpoint_task_id=' "$dir/home/state/hd.meta" \
    || fail 'a failed server ensure was persisted as a verdict'
  pass 'a herdr recheck whose server never starts stays retryable'
}

test_rerun_converges_after_interruption() {
  local dir out rc
  dir=$(make_case interruption)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
real_mv=$FM_REAL_MV
count_file=$FM_MV_COUNT
count=0
[ -f "$count_file" ] && count=$(cat "$count_file")
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
"$real_mv" "$@"
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
if [ "$count" -eq 1 ]; then
  kill -TERM "$FM_MIGRATE_PID"
fi
SH
  chmod +x "$dir/fakebin/mv"
  set +e
  out=$(FM_REAL_MV=$(command -v mv) FM_MV_COUNT="$dir/mv.count" run_locked "$dir")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "interrupted scan unexpectedly succeeded: $out"
  out=$(run_locked "$dir") || fail "rerun failed: $out"
  grep -qx 'endpoint_task_id=good' "$dir/home/state/good.meta" \
    || fail 'rerun did not converge the interrupted scan'
  pass 'rerunning after interruption converges without migration state'
}

test_refusal_reasons_are_per_record() {
  local dir out
  dir=$(make_case refusals)
  fm_write_meta "$dir/home/state/ambiguous.meta" \
    'window=firstmate:fm-ambiguous' "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  fm_write_meta "$dir/home/state/unreadable.meta" \
    'window=firstmate:fm-unreadable' "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  fm_write_meta "$dir/home/state/unverified.meta" \
    'window=zellij:2' 'backend=zellij' 'zellij_session=zellij' 'zellij_tab_id=1' \
    'zellij_pane_id=2' "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  fm_write_meta "$dir/home/state/mismatch.meta" \
    'window=firstmate:fm-mismatch' "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'

  out=$(FM_FAKE_MODE=refusals run_locked "$dir") || fail "refusal scan failed: $out"
  ! grep -q '^endpoint_task_id=' "$dir/home/state/ambiguous.meta" \
    || fail 'ambiguous endpoint was stamped'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/unreadable.meta" \
    || fail 'unreadable endpoint was stamped'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/unverified.meta" \
    || fail 'unverified endpoint was stamped'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/mismatch.meta" \
    || fail 'mismatched endpoint was stamped'
  ! grep -q '^endpoint_binding_verdict=' "$dir"/home/state/*.meta \
    || fail 'a failed or inconclusive observation was persisted as a terminal verdict'
  [ -z "$out" ] || fail "retryable refusals printed output: $out"
  pass 'retryable refusals are never stamped or persisted, so the next start re-probes them'
}

test_hidden_records_are_out_of_scope() {
  local dir out
  dir=$(make_case hidden)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  fm_write_meta "$dir/home/state/.meta" \
    'window=firstmate:fm-dead' "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  fm_write_meta "$dir/home/state/.hidden.meta" \
    'window=firstmate:fm-bound' "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'

  out=$(run_locked "$dir") || fail "hidden record scan failed: $out"
  ! grep -q '^endpoint_task_id=' "$dir/home/state/.meta" \
    || fail 'hidden metadata record was stamped'
  ! grep -q '^endpoint_task_id=' "$dir/home/state/.hidden.meta" \
    || fail 'hidden metadata record was stamped'
  grep -qx 'endpoint_task_id=good' "$dir/home/state/good.meta" \
    || fail 'scan did not continue past hidden metadata records'
  pass 'hidden metadata records are out of scope and never stamped'
}

test_locked_record_is_skipped_without_waiting() {
  local dir out lock
  dir=$(make_case contended)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" 'kind=scout'
  lock="$dir/home/state/.meta-good.lock"
  mkdir -p "$lock"
  printf '%s\n' "$$" > "$lock/pid"

  out=$(run_locked "$dir") || fail "contended scan failed: $out"
  ! grep -q '^endpoint_task_id=\|^endpoint_binding_verdict=' "$dir/home/state/good.meta" \
    || fail 'record held by another operation was changed'
  [ -z "$out" ] || fail "contended scan printed output: $out"

  rm -rf "$lock"
  out=$(run_locked "$dir") || fail "rerun after contention failed: $out"
  grep -qx 'endpoint_task_id=good' "$dir/home/state/good.meta" \
    || fail 'rerun did not converge the contended record'
  pass 'a contended record is skipped silently and converges on rerun'
}

test_stamped_record_keeps_pr_metadata_valid() {
  local dir out
  dir=$(make_case prmeta)
  fm_write_meta "$dir/home/state/good.meta" \
    'window=firstmate:fm-good' "worktree=$dir/worktree" "project=$dir/project" 'kind=scout' \
    'pr=https://github.com/owner/repo/pull/7' \
    'pr_head=0123456789abcdef0123456789abcdef01234567'
  ( . "$ROOT/bin/fm-pr-lib.sh"; fm_pr_metadata_identity_parse "$dir/home/state/good.meta" ) \
    || fail 'baseline legacy record was already invalid to fm-pr-lib'

  out=$(run_locked "$dir") || fail "pr metadata scan failed: $out"
  grep -qx 'endpoint_task_id=good' "$dir/home/state/good.meta" \
    || fail 'live exact endpoint was not stamped'
  ( . "$ROOT/bin/fm-pr-lib.sh"; fm_pr_metadata_identity_parse "$dir/home/state/good.meta" ) \
    || fail 'stamped record no longer parses as valid PR metadata'
  ! grep -qx '' "$dir/home/state/good.meta" \
    || fail 'stamped record gained a blank line'
  pass 'stamping preserves the record PR metadata contract without blank lines'
}

test_evidence_bound_scan
test_rerun_is_silent_and_never_reprobes_verdicts
test_missing_endpoints_are_terminal_and_free
test_record_shape_refusal_is_terminal
test_retryable_probes_are_bounded_per_start
test_unsupported_backends_are_skipped_before_budget
test_herdr_absent_pane_is_terminal
test_herdr_stopped_server_recheck_stays_retryable
test_herdr_failed_server_ensure_stays_retryable
test_rerun_converges_after_interruption
test_refusal_reasons_are_per_record
test_hidden_records_are_out_of_scope
test_locked_record_is_skipped_without_waiting
test_stamped_record_keeps_pr_metadata_valid
