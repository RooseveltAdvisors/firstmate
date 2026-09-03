#!/usr/bin/env bash
# tests/fm-backlog-read-bound.test.sh - behavior tests for the per-item bound on
# bin/fm-backlog-transition-lib.sh's backlog row read.
#
# The defect this pins: bin/fm-bootstrap.sh's reconcile and close-replay sweeps
# read the backlog backend once per item, and an unbounded read of a wedged
# backend consumed the whole FM_SESSION_START_TIMEOUT. The digest was then
# truncated before the wake queue, supervision instructions, fleet state, and
# context sections printed, leaving a whole fleet unsupervised.
#
# Both halves are proved here:
#   - a deliberately hanging `tasks-axi show` cannot exceed the per-item bound,
#     and the failure names the item it could not read
#   - a session start against that same wedged backend still completes end to
#     end, with every digest section present and a loud partial reconcile
#
# The bound must hold on its own, independent of any particular tasks-axi
# install, so the fake here simply never returns.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-backlog-read-bound-tests)
trap fm_test_cleanup EXIT

BOUND_SECS=2
# Generous enough that a slow CI box never flakes, far below the unbounded hang
# (300s per read) and below the session-start budget the defect consumed.
BOUND_CEILING=30

# A backend whose `show` never returns. Everything the compatibility gate and the
# startup listing need still answers promptly, so the only thing under test is
# the read that hangs.
make_hanging_tasks_axi() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf '%s\n' '0.2.5'; exit 0 ;;
  update)
    [ "${2:-}" = --help ] || exit 0
    printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --body-file <path>' '  --archive-body'
    exit 0
    ;;
  mv)
    [ "${2:-}" = --help ] || exit 0
    printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
    exit 0
    ;;
  show)
    # The wedge under test: a read that never returns.
    sleep 300
    exit 0
    ;;
  list)
    printf 'count: 0\n'
    printf 'tasks[0]{id,state,kind,repo,title,blocked_by,hold_kind,hold_reason}:\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

elapsed_since() {  # <start-epoch>
  local now
  now=$(date +%s)
  printf '%s\n' "$((now - $1))"
}

# --- half one: the per-item bound holds -------------------------------------

UNIT="$TMP_ROOT/unit"
UNIT_FAKEBIN=$(fm_fakebin "$UNIT")
mkdir -p "$UNIT/data"
make_hanging_tasks_axi "$UNIT_FAKEBIN"
printf '# Backlog\n' > "$UNIT/data/backlog.md"

# Three items, so "every skipped item is still named" is actually exercised
# rather than inferred from a single skip.
PROBE_OUT="$UNIT/probe.out"
PATH="$UNIT_FAKEBIN:$BASE_PATH" FM_BACKLOG_ROW_TIMEOUT_SECS="$BOUND_SECS" \
  bash -c '
    set -u
    . "$1/bin/fm-tasks-axi-lib.sh"
    . "$1/bin/fm-backlog-transition-lib.sh"
    for id in wedged-one wedged-two wedged-three; do
      start=$(date +%s)
      fm_backlog_row_probe "$2" "$id" && printf "unexpected-success\n"
      printf "elapsed:%s=%s\n" "$id" "$(( $(date +%s) - start ))"
      printf "error:%s=%s\n" "$id" "$FM_BACKLOG_ROW_ERROR"
    done
  ' _ "$ROOT" "$UNIT/data" > "$PROBE_OUT" 2>&1

probe_elapsed() {  # <id>
  sed -n "s/^elapsed:$1=//p" "$PROBE_OUT"
}

probe_error() {  # <id>
  sed -n "s/^error:$1=//p" "$PROBE_OUT"
}

grep -q '^unexpected-success$' "$PROBE_OUT" \
  && fail "a hanging tasks-axi show must not report a successful row read: $(cat "$PROBE_OUT")"

FIRST_ELAPSED=$(probe_elapsed wedged-one)
[ -n "$FIRST_ELAPSED" ] || fail "probe produced no timing: $(cat "$PROBE_OUT")"
[ "$FIRST_ELAPSED" -lt "$BOUND_CEILING" ] \
  || fail "bounded row read took ${FIRST_ELAPSED}s, over the ${BOUND_CEILING}s ceiling: $(cat "$PROBE_OUT")"
pass "a hanging tasks-axi show returns within the per-item bound instead of running unbounded"

FIRST_ERROR=$(probe_error wedged-one)
case "$FIRST_ERROR" in
  *wedged-one*bound*) ;;
  *) fail "the timed-out read must name the item and its bound, got: $FIRST_ERROR" ;;
esac
pass "a timed-out row read reports one error naming the item that timed out"

# The latch is what keeps a home carrying a large fleet from paying N bounds and
# losing the digest anyway, so assert it strictly: a latched read must be
# FASTER than one bound, not merely under the ceiling. A ceiling-only assertion
# passes whether or not the latch works, and fm_backlog_row_show runs inside a
# command substitution whose writes die with the subshell - the exact way this
# latch can silently become inert.
for SKIPPED in wedged-two wedged-three; do
  SKIPPED_ERROR=$(probe_error "$SKIPPED")
  SKIPPED_ELAPSED=$(probe_elapsed "$SKIPPED")
  case "$SKIPPED_ERROR" in
    *"$SKIPPED"*skipped*) ;;
    *) fail "every skipped item must still be named as skipped, $SKIPPED got: $SKIPPED_ERROR" ;;
  esac
  [ -n "$SKIPPED_ELAPSED" ] && [ "$SKIPPED_ELAPSED" -lt "$BOUND_SECS" ] \
    || fail "the latch is inert: $SKIPPED paid ${SKIPPED_ELAPSED}s against a known-wedged backend"
done
pass "after the first bound hit the sweep continues and names every remaining item without paying the bound again"

# --- half two: the digest still completes end to end ------------------------

E2E="$TMP_ROOT/e2e"
E2E_ROOT="$E2E/root"
E2E_HOME="$E2E/home"
E2E_FAKEBIN="$E2E/fakebin"
mkdir -p "$E2E_HOME/state" "$E2E_HOME/data" "$E2E_HOME/config" "$E2E_FAKEBIN"
git init -q -b main "$E2E_ROOT"
git -C "$E2E_ROOT" commit -q --allow-empty -m init

make_hanging_tasks_axi "$E2E_FAKEBIN"
fm_fake_exit0 "$E2E_FAKEBIN" tmux node chrome-devtools-axi gh treehouse
fm_fake_version_tool "$E2E_FAKEBIN" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
fm_fake_version_tool "$E2E_FAKEBIN" gh-axi FM_FAKE_GH_AXI_VERSION 0.1.29
fm_fake_version_tool "$E2E_FAKEBIN" no-mistakes FM_FAKE_NO_MISTAKES_VERSION \
  'no-mistakes version v1.46.0 (fake) 2026-06-27T00:02:18Z'

printf '# Backlog\n' > "$E2E_HOME/data/backlog.md"
# One owned record, so the reconcile sweep actually reads the wedged backend.
fm_write_meta "$E2E_HOME/state/wedged-task.meta" \
  'window=firstmate:fm-wedged-task' \
  'worktree=/nonexistent/wedged-task' \
  'project=alpha' \
  'harness=claude' \
  'mode=no-mistakes' \
  'yolo=off'

DIGEST="$E2E/digest.out"
DIGEST_START=$(date +%s)
env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
  FM_HOME="$E2E_HOME" FM_ROOT_OVERRIDE="$E2E_ROOT" PATH="$E2E_FAKEBIN:$BASE_PATH" \
  FM_BACKLOG_ROW_TIMEOUT_SECS="$BOUND_SECS" \
  "$ROOT/bin/fm-session-start.sh" > "$DIGEST" 2>&1 || true
DIGEST_ELAPSED=$(elapsed_since "$DIGEST_START")

[ "$DIGEST_ELAPSED" -lt "$BOUND_CEILING" ] \
  || fail "session start took ${DIGEST_ELAPSED}s against a wedged backlog backend"

for SECTION in 'WAKE QUEUE' 'SUPERVISION OPERATING INSTRUCTIONS' 'FLEET STATE' 'CONTEXT'; do
  grep -q "$SECTION" "$DIGEST" \
    || fail "the digest lost its $SECTION section against a wedged backlog backend: $(cat "$DIGEST")"
done
pass "a wedged backlog backend still leaves a complete digest: wake queue, supervision instructions, fleet state, and context all print"

grep -q '^BACKLOG_RECONCILE: wedged-task: ' "$DIGEST" \
  || fail "the wedged item must be reported by name as a partial reconcile: $(cat "$DIGEST")"
pass "an unreachable backlog backend degrades to a loud partial reconcile naming the item it could not read"

echo "# fm-backlog-read-bound.test.sh: all assertions passed"
