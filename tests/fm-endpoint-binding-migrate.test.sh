#!/usr/bin/env bash
set -u

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
  printf '%s\n' fm-good fm-dead fm-bound
  exit 0
fi
if [ "$1" = display-message ]; then
  case "$5" in
    '#{pane_tty}') printf '/dev/null\n' ;;
    '#{pane_current_command}')
      [ "$4" = '=firstmate:=fm-good' ] && printf 'pi\n' || printf 'bash\n'
      ;;
    '#{pane_current_path}') printf '%s\n' "$FM_LIVE_WORKTREE" ;;
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
    export PATH="$dir/fakebin:$BASE_PATH" FM_LIVE_WORKTREE="$dir/worktree"
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
  assert_contains "$out" 'task good: stamped - exact live endpoint identity verified' 'stamp was not reported'
  assert_contains "$out" 'task dead: skipped - dead endpoint' 'dead endpoint was not reported'
  pass 'endpoint binding scan stamps only a verified live identity'
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

test_evidence_bound_scan
test_rerun_converges_after_interruption
