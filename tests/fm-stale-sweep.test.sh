#!/usr/bin/env bash
# Tests for bin/fm-stale-sweep.sh - the dead-endpoint stale-claim reclaim
# sweep over the shared Beads graph.
#
# Fixture: one firstmate home whose .tasks.toml points at a scratch Beads
# graph, holding four stale in_progress rows:
#   - fm-dead-row: owned by this home, endpoint dead (missing tmux target)
#   - fm-live-row: owned by this home, endpoint live (busy semantic record)
#   - fm-orphan-row: no owning home anywhere (no meta, no provenance)
#   - fm-prov-row: provenance names a markdown home with no meta; its reclaim
#     must fall back to the graph-owning sweep home for the mutation while the
#     note still names the provenance actor
#
# The dry run must list all four with the right verdicts and reclaim nothing;
# --apply must reopen exactly the dead rows with the reclaim note appended and
# never touch the live or unowned ones, and never remove a meta file. The
# `check` mode must print one line only when rows are reclaimable, gate itself
# on the interval record, and arm/disarm must write, register, and remove the
# watcher check shim.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

SWEEP="$ROOT/bin/fm-stale-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-stale-sweep)

# A fakebin whose tmux answers every target except the dead row's window, and
# whose no-mistakes reports no run anywhere (crew-state's run lookup finds
# nothing, so verdicts come from the pane/busy-record paths).
make_fakebin() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in *%dead*) exit 1 ;; esac
    done
    printf '%%1\n'
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status) shift; printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;;
      logs) printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
    esac
    ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  chmod +x "$fb/tmux" "$fb/no-mistakes"
  printf '%s\n' "$fb"
}

# A real git repo checked out on <branch> so crew-state's run attribution has a
# branch to read.
make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
}

# Build the fixture: home + scratch beads graph + four rows + metas. Echoes
# "<case>|<home>|<fakebin>". The graph repo dir is named "fm" because bd
# derives the row-id prefix from the repo directory name.
make_fixture() {  # <name>
  local name=$1 case_dir home graph fb
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  graph="$case_dir/fm"
  mkdir -p "$home/data" "$home/state" "$graph" "$case_dir/other-home"
  fb=$(make_fakebin "$case_dir")
  git -C "$graph" init -q
  (cd "$graph" && bd init >/dev/null 2>&1)
  cat > "$home/.tasks.toml" <<EOF
backend = "beads"

[beads]
path = "$graph/.beads"
binary = "bd"
prefix = "fm"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
EOF
  for id in fm-dead-row fm-live-row fm-orphan-row fm-prov-row; do
    (cd "$home" && tasks-axi add "$id" "fixture $id" --kind ship >/dev/null)
    (cd "$home" && tasks-axi start "$id" >/dev/null)
  done
  (cd "$home" && tasks-axi update fm-prov-row --body \
    "Provenance: imported 2026-09-01 from secondmate home widgets ($case_dir/other-home) markdown backlog" >/dev/null)
  make_repo_on_branch "$case_dir/wt-dead" fm/dead
  make_repo_on_branch "$case_dir/wt-live" fm/live
  fm_write_meta "$home/state/fm-dead-row.meta" \
    "window=firstmate:%dead" "worktree=$case_dir/wt-dead" "kind=ship" "harness=claude"
  fm_write_meta "$home/state/fm-live-row.meta" \
    "window=firstmate:%live" "worktree=$case_dir/wt-live" "kind=ship" "harness=claude"
  # The live row's endpoint is provably working: a semantic busy record.
  local gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" fm-live-row)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" fm-live-row busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  printf '%s\n' "$case_dir|$home|$fb"
}

read_fixture() {
  IFS='|' read -r CASE_DIR HOME_DIR FAKEBIN <<EOF
$1
EOF
}

# A background process holding one per-task record lock the way a completing
# teardown does (the wake-lib lock protocol), so the sweep's contention path
# is exercised against a real holder.
make_lock_holder() {  # <dir>
  local dir=$1
  cat > "$dir/holder.sh" <<SH
#!/usr/bin/env bash
set -u
FM_ROOT_OVERRIDE="$ROOT"
FM_STATE_OVERRIDE="$dir/holder-state"
. "$ROOT/bin/fm-wake-lib.sh"
fm_lock_try_acquire "\$1" >/dev/null 2>&1 || exit 3
sleep 20
fm_lock_release "\$1" >/dev/null 2>&1
SH
  chmod +x "$dir/holder.sh"
}

row_state() {  # <id>
  (cd "$HOME_DIR" && tasks-axi show "$1" 2>/dev/null) | sed -n 's/^  state: *//p' | head -1
}

row_body() {  # <id>
  (cd "$HOME_DIR" && tasks-axi show "$1" --full 2>/dev/null) | sed -n 's/^  body: //p' | head -1
}

# assert_row_matches <ere> <haystack> <msg>: one table row must match the
# pattern (lib.sh's assert_grep is fixed-string against a file, and the table's
# column padding needs a regex).
assert_row_matches() {
  printf '%s\n' "$2" | grep -Eq -- "$1" || fail "$3"
}

# The sweep clock runs 50 hours ahead so the freshly created rows are 26 hours
# stale against the default 24h threshold.
sweep_clock() {
  echo $(( $(date +%s) + 50 * 3600 ))
}

run_sweep() {  # [args...]
  FM_HOME="$HOME_DIR" FM_STALE_SWEEP_NOW="$(sweep_clock)" \
    PATH="$FAKEBIN:$PATH" "$SWEEP" "$@"
}

test_dry_run_lists_verdicts_and_reclaims_nothing() {
  local rec out rc
  rec=$(make_fixture dry)
  read_fixture "$rec"
  out=$(run_sweep)
  rc=$?
  expect_code 0 "$rc" "dry run should succeed"
  assert_contains "$out" "fm-dead-row" "dry run table lists the dead row"
  assert_contains "$out" "fm-live-row" "dry run table lists the live row"
  assert_contains "$out" "fm-orphan-row" "dry run table lists the unowned row"
  assert_contains "$out" "fm-prov-row" "dry run table lists the provenance row"
  assert_row_matches 'fm-dead-row[[:space:]]+main home[[:space:]]+26h[[:space:]]+dead[[:space:]]+would reclaim' "$out" \
    "dead endpoint row must read dead / would reclaim"
  assert_row_matches 'fm-live-row[[:space:]]+main home[[:space:]]+26h[[:space:]]+live[[:space:]]+keep' "$out" \
    "live endpoint row must read live / keep"
  assert_row_matches 'fm-orphan-row[[:space:]]+-[[:space:]]+26h[[:space:]]+no-home[[:space:]]+keep' "$out" \
    "unowned row must read no-home / keep"
  assert_row_matches 'fm-prov-row[[:space:]]+widgets[[:space:]]+26h[[:space:]]+dead[[:space:]]+would reclaim' "$out" \
    "provenance row must read dead under the provenance actor"
  assert_contains "$out" "4 stale candidates: 2 dead, 1 live, 0 unproven, 1 no-home; would reclaim 2" \
    "summary must count the dry-run verdicts"
  [ "$(row_state fm-dead-row)" = in_flight ] || fail "dry run changed the dead row's state"
  [ "$(row_state fm-live-row)" = in_flight ] || fail "dry run changed the live row's state"
  [ "$(row_state fm-orphan-row)" = in_flight ] || fail "dry run changed the unowned row's state"
  [ -f "$HOME_DIR/state/fm-dead-row.meta" ] || fail "dry run removed a meta file"
  pass "dry run lists every verdict and reclaims nothing"
}

test_apply_reclaims_only_dead_rows() {
  local rec out rc date
  rec=$(make_fixture apply)
  read_fixture "$rec"
  out=$(run_sweep --apply)
  rc=$?
  expect_code 0 "$rc" "apply run should succeed"
  assert_row_matches 'fm-dead-row[[:space:]]+main home[[:space:]]+26h[[:space:]]+dead[[:space:]]+reclaimed' "$out" \
    "dead endpoint row must be reclaimed"
  assert_row_matches 'fm-live-row[[:space:]]+main home[[:space:]]+26h[[:space:]]+live[[:space:]]+keep' "$out" \
    "live endpoint row must stay untouched"
  assert_row_matches 'fm-orphan-row[[:space:]]+-[[:space:]]+26h[[:space:]]+no-home[[:space:]]+keep' "$out" \
    "unowned row must stay untouched"
  assert_row_matches 'fm-prov-row[[:space:]]+widgets[[:space:]]+26h[[:space:]]+dead[[:space:]]+reclaimed' "$out" \
    "provenance row must be reclaimed through the sweep home"
  assert_contains "$out" "reclaimed 2" "summary must count the reclaims"
  [ "$(row_state fm-dead-row)" = queued ] || fail "dead row was not reopened to queued"
  [ "$(row_state fm-prov-row)" = queued ] || fail "provenance row was not reopened to queued"
  [ "$(row_state fm-live-row)" = in_flight ] || fail "apply touched the live row"
  [ "$(row_state fm-orphan-row)" = in_flight ] || fail "apply touched the unowned row"
  date=$(date +%F)
  assert_contains "$(row_body fm-dead-row)" "reclaimed $date: endpoint dead, previous claim by main home" \
    "dead row body must carry the reclaim note with the owning actor"
  assert_contains "$(row_body fm-prov-row)" "reclaimed $date: endpoint dead, previous claim by widgets" \
    "provenance row body must carry the reclaim note with the provenance actor"
  [ "$(row_body fm-live-row)" = '""' ] || [ -z "$(row_body fm-live-row)" ] || [ "$(row_body fm-live-row)" = '"-"' ] \
    || fail "apply appended a note to the live row"
  [ -f "$HOME_DIR/state/fm-dead-row.meta" ] || fail "apply removed the dead row's meta file"
  [ -f "$HOME_DIR/state/fm-live-row.meta" ] || fail "apply removed the live row's meta file"
  pass "apply reclaims exactly the dead rows with the note, touching nothing else"
}

test_check_mode_gates_on_the_interval_record() {
  local rec out t0
  rec=$(make_fixture check)
  read_fixture "$rec"
  t0=$(( $(date +%s) + 50 * 3600 ))
  out=$(FM_HOME="$HOME_DIR" FM_STALE_SWEEP_NOW=$t0 PATH="$FAKEBIN:$PATH" "$SWEEP" check)
  assert_contains "$out" "stale-sweep: 2 dead-endpoint in_progress rows reclaimable" \
    "first check must report the reclaimable rows"
  [ -f "$HOME_DIR/state/.stale-sweep" ] || fail "first check wrote no probe record"
  # Ten minutes later: inside the interval gate, must stay silent.
  out=$(FM_HOME="$HOME_DIR" FM_STALE_SWEEP_NOW=$((t0 + 600)) PATH="$FAKEBIN:$PATH" "$SWEEP" check)
  [ -z "$out" ] || fail "check inside the interval gate printed: $out"
  # After a full day: the gate reopens.
  out=$(FM_HOME="$HOME_DIR" FM_STALE_SWEEP_NOW=$((t0 + 86401)) PATH="$FAKEBIN:$PATH" "$SWEEP" check)
  assert_contains "$out" "stale-sweep: 2 dead-endpoint in_progress rows reclaimable" \
    "check after the interval must report again"
  # A clean graph stays silent even past the gate.
  FM_HOME="$HOME_DIR" FM_STALE_SWEEP_NOW=$((t0 + 50 * 3600)) PATH="$FAKEBIN:$PATH" "$SWEEP" --apply >/dev/null
  out=$(FM_HOME="$HOME_DIR" FM_STALE_SWEEP_NOW=$((t0 + 100 * 3600)) PATH="$FAKEBIN:$PATH" "$SWEEP" check)
  [ -z "$out" ] || fail "check on a clean graph printed: $out"
  pass "check mode reports only past the interval gate and only when rows are reclaimable"
}

test_check_mode_reports_the_budget_cut() {
  local rec out
  rec=$(make_fixture cut)
  read_fixture "$rec"
  # FM_CHECK_TIMEOUT=8 cuts the 25s budget to 5 (CHECK_TIMEOUT-3), so the
  # check must report the cut alongside its reclaimable verdict.
  out=$(FM_HOME="$HOME_DIR" FM_CHECK_TIMEOUT=8 FM_STALE_SWEEP_NOW="$(sweep_clock)" \
    PATH="$FAKEBIN:$PATH" "$SWEEP" check)
  assert_contains "$out" "note: FM_STALE_SWEEP_BUDGET_SECS 25 cut to 5 to fit FM_CHECK_TIMEOUT" \
    "check mode must report the budget cut instead of swallowing it"
  printf '%s\n' "$out" | grep -q "^stale-sweep: " || fail "the cut note must not replace the reclaimable report"
  pass "check mode reports the budget cut alongside its reclaimable verdict"
}

test_apply_names_the_resolved_homes_actor_when_two_homes_hold_meta() {
  local rec out date
  rec=$(make_fixture handoff)
  read_fixture "$rec"
  # A second registered home also holding the dead row's meta is the handoff
  # seam; the resolved home stays this home (listed first), so the reclaim note
  # must carry this home's actor, not the last-scanned registry home's id.
  mkdir -p "$CASE_DIR/other-home/state"
  fm_write_meta "$CASE_DIR/other-home/state/fm-dead-row.meta" \
    "window=firstmate:%dead" "worktree=$CASE_DIR/wt-dead" "kind=ship" "harness=claude"
  printf '%s\n' "- widgets2 - handoff twin (home: $CASE_DIR/other-home; repo: -)" \
    > "$HOME_DIR/data/secondmates.md"
  out=$(run_sweep --apply)
  date=$(date +%F)
  assert_contains "$(row_body fm-dead-row)" "reclaimed $date: endpoint dead, previous claim by main home" \
    "the note must name the resolved first home's actor, not the last scanned one"
  [ "$(row_state fm-dead-row)" = queued ] || fail "the dead row was not reclaimed"
  pass "a two-home handoff reclaims through the first home and names its actor"
}

# A bd that hangs: in check mode the graph read must be bounded by the budget
# so the probe fails visibly (with its record written) instead of being killed
# silently by the watcher's timeout.
test_check_mode_bounds_the_graph_read() {
  local rec out t0 bdslow="$TMP_ROOT/bdslow/fakebin"
  rec=$(make_fixture bdslow)
  read_fixture "$rec"
  mkdir -p "$bdslow"
  cat > "$bdslow/bd" <<'SH'
#!/usr/bin/env bash
sleep 5
exit 0
SH
  chmod +x "$bdslow/bd"
  t0=$(sweep_clock)
  out=$(FM_HOME="$HOME_DIR" FM_CHECK_TIMEOUT=3 FM_STALE_SWEEP_NOW=$t0 \
    PATH="$bdslow:$FAKEBIN:$PATH" "$SWEEP" check)
  assert_contains "$out" "fm-stale-sweep: graph read failed" \
    "a graph read that exceeds the budget must fail visibly, not silently"
  # The probe record is still written, so the next poll inside the interval
  # stays quiet instead of retrying a doomed read every poll.
  out=$(FM_HOME="$HOME_DIR" FM_CHECK_TIMEOUT=3 FM_STALE_SWEEP_NOW=$((t0 + 600)) \
    PATH="$bdslow:$FAKEBIN:$PATH" "$SWEEP" check)
  [ -z "$out" ] || fail "check inside the interval gate printed: $out"
  pass "check mode bounds the graph read by the budget and records the failed probe"
}

test_arm_disarm_roundtrip() {
  local rec
  rec=$(make_fixture arm)
  read_fixture "$rec"
  FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$SWEEP" arm >/dev/null \
    || fail "arm failed"
  [ -f "$HOME_DIR/state/stale-sweep.check.sh" ] || fail "arm wrote no check shim"
  [ -f "$HOME_DIR/state/stale-sweep.check-trust" ] || fail "arm registered no trust binding"
  [ "$(stat -c %a "$HOME_DIR/state/stale-sweep.check.sh")" = 700 ] \
    || fail "check shim is not mode 0700"
  FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$SWEEP" disarm >/dev/null \
    || fail "disarm failed"
  [ ! -e "$HOME_DIR/state/stale-sweep.check.sh" ] || fail "disarm left the shim"
  [ ! -e "$HOME_DIR/state/stale-sweep.check-trust" ] || fail "disarm left the trust binding"
  [ ! -e "$HOME_DIR/state/.stale-sweep" ] || fail "disarm left the report record"
  pass "arm writes and registers the check shim; disarm removes all of it"
}

# A record lock held by another actor: a completion (teardown's meta removal
# plus `tasks-axi done`) owns the row right now, so the sweep must refuse the
# row instead of racing the close and resurrecting finished work. After the
# holder dies, the same sweep reclaims the row, proving the lock was the gate.
test_apply_refuses_a_row_whose_record_lock_a_completion_holds() {
  local rec out holder_pid lock
  rec=$(make_fixture lockheld)
  read_fixture "$rec"
  make_lock_holder "$CASE_DIR"
  lock="$HOME_DIR/state/.meta-fm-dead-row.lock"
  "$CASE_DIR/holder.sh" "$lock" >/dev/null 2>&1 &
  holder_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$lock" ] && break
    sleep 0.1
  done
  [ -e "$lock" ] || fail "fixture holder never took the record lock"
  out=$(run_sweep --apply)
  assert_row_matches \
    'fm-dead-row[[:space:]]+main home[[:space:]]+26h[[:space:]]+dead[[:space:]]+reclaim failed: record locked by another actor' \
    "$out" "a row whose record lock a completion holds must be refused, not reopened"
  [ "$(row_state fm-dead-row)" = in_flight ] || fail "the sweep touched a row whose record lock was held"
  assert_contains "$out" "reclaimed 1" \
    "the summary must count only the row the lock did not protect"
  [ "$(row_state fm-prov-row)" = queued ] \
    || fail "a record home with no state dir must still reclaim (no lock to share)"
  kill "$holder_pid" 2>/dev/null
  wait "$holder_pid" 2>/dev/null
  out=$(run_sweep --apply)
  assert_row_matches 'fm-dead-row[[:space:]]+main home[[:space:]]+26h[[:space:]]+dead[[:space:]]+reclaimed' "$out" \
    "once no completion holds the record lock, the same sweep must reclaim the row"
  [ "$(row_state fm-dead-row)" = queued ] || fail "the row was not reclaimed after the lock freed"
  [ ! -e "$lock" ] || fail "the sweep left the record lock behind after reclaiming"
  pass "a row whose record lock a completion holds is refused until the lock frees"
}

# A pending backlog-close replay record: a completion was recorded and is still
# owed (the teardown crash window), so the row must never be reopened.
test_apply_refuses_a_row_with_a_pending_completion_replay() {
  local rec out
  rec=$(make_fixture closereplay)
  read_fixture "$rec"
  {
    printf 'id=fm-dead-row\n'
    printf 'data=%s/data\n' "$HOME_DIR"
    printf 'spawn_gen=fm-dead-row-gen\n'
    printf 'cleanup_incomplete=0\n'
  } > "$HOME_DIR/state/fm-dead-row.backlog-close"
  out=$(run_sweep --apply)
  assert_row_matches \
    'fm-dead-row[[:space:]]+main home[[:space:]]+26h[[:space:]]+dead[[:space:]]+reclaim failed: completion replay pending' \
    "$out" "a row with a pending completion replay must be refused, not reopened"
  [ "$(row_state fm-dead-row)" = in_flight ] || fail "the sweep touched a row whose completion is still owed"
  rm -f "$HOME_DIR/state/fm-dead-row.backlog-close"
  run_sweep --apply >/dev/null
  [ "$(row_state fm-dead-row)" = queued ] \
    || fail "the row was not reclaimed once no completion was pending"
  pass "a row with a pending completion replay is refused until the replay lands"
}

test_dry_run_lists_verdicts_and_reclaims_nothing
test_apply_reclaims_only_dead_rows
test_apply_refuses_a_row_whose_record_lock_a_completion_holds
test_apply_refuses_a_row_with_a_pending_completion_replay
test_apply_names_the_resolved_homes_actor_when_two_homes_hold_meta
test_check_mode_gates_on_the_interval_record
test_check_mode_reports_the_budget_cut
test_check_mode_bounds_the_graph_read
test_arm_disarm_roundtrip

echo "# all fm-stale-sweep tests passed"
