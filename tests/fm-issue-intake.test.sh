#!/usr/bin/env bash
# tests/fm-issue-intake.test.sh - the fleet issue dispatch loop's intake: one task row
# (a bead on a beads backend) per SOS keyed on the SOS UUID, one lifecycle
# comment per transition, one close watch per ticket, one dispatched crewmate
# per new ticket - and never a second of any of them across retries, replayed
# events, or lost cursors. Also pins the loop's hard invariant: intake and the
# close watch close a GitHub issue only for a not-supported decline; every
# other close belongs to the captain.
set -u

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTAKE="$ROOT/bin/fm-issue-intake.sh"
TASKS_AXI="$ROOT/bin/fm-tasks-axi.sh"
SOS_UUID="7f3c1a52-9b41-4c2e-9d6a-1f0b2c3d4e5f"
TASK_ID="fm-iss-$SOS_UUID"
GH_ISSUE=1921

TMP_ROOT=$(fm_test_tmproot fm-issue-intake)

# setup_case <name>: a fixture home with a real tasks-axi backlog (markdown
# backend - the beads-capable backend is the fleet's, and the intake reaches
# it through the same fm-tasks-axi.sh entry point), a fakebin holding stub
# gh/curl/fm-spawn, and the canned bridge/GitHub scenario files the stubs
# serve. Echoes "<home>|<fakebin>|<fakedir>".
setup_case() {
  local name=$1 case_dir home fb fd
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fd="$case_dir/fake"
  mkdir -p "$home/data" "$fd"
  (umask 077; mkdir -p "$home/state")
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  fb=$(fm_fakebin "$case_dir")

  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
FAKE="${FM_ISSUE_FAKE_DIR:?}"
echo "gh $*" >> "$FAKE/gh.log"
if [ -f "$FAKE/gh-broken" ]; then
  echo "gh: simulated outage" >&2
  exit 1
fi
case "${1:-}" in
  issue)
    case "${2:-}" in
      list) cat "$FAKE/gh-list.json" 2>/dev/null || echo "[]" ;;
      view)
        n="${3:-}"
        case "$*" in
          *--json*title*)
            if [ -f "$FAKE/gh-view-$n.json" ]; then cat "$FAKE/gh-view-$n.json"
            else echo '{"title":"SOS: reported problem","body":"body","labels":[{"name":"sos"}]}'
            fi ;;
          *)
            if [ -f "$FAKE/gh-state-$n" ]; then cat "$FAKE/gh-state-$n"; else echo '{"state":"OPEN"}'; fi ;;
        esac
        ;;
      edit)
        n="${3:-}"
        echo "edit $n $*" >> "$FAKE/edit.log"
        exit 0 ;;
      comment)
        n="${3:-}"
        shift 3
        body=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "--body" ] && [ $# -ge 2 ]; then body="$2"; shift; fi
          shift
        done
        printf '%s\t%s\n' "$n" "$body" >> "$FAKE/comments.log"
        echo "https://github.com/ArcsHealth/Portal/issues/$n#comment-1"
        ;;
      close)
        echo "CLOSE-ATTEMPTED" >> "$FAKE/gh.log"
        # The loop closes an issue only on a decline; every other path must
        # fail here, which pins every close to that one carve-out.
        [ -f "$FAKE/allow-close" ] && exit 0
        exit 97 ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH

  cat > "$fb/curl" <<'SH'
#!/usr/bin/env bash
set -u
FAKE="${FM_ISSUE_FAKE_DIR:?}"
echo "curl $*" >> "$FAKE/curl.log"
cat "$FAKE/bridge.json"
SH

  cat > "$fb/fm-spawn" <<'SH'
#!/usr/bin/env bash
set -u
FAKE="${FM_ISSUE_FAKE_DIR:?}"
echo "fm-spawn $*" >> "$FAKE/spawn.log"
[ -f "$FAKE/spawn-fail" ] && exit 1
exit 0
SH

  cat > "$fb/jev" <<'SH'
#!/usr/bin/env bash
set -u
FAKE="${FM_ISSUE_FAKE_DIR:?}"
echo "jev $*" >> "$FAKE/jev.log"
[ -f "$FAKE/jev-verdict" ] || { echo '{"verdict":"supported_bug","confidence":0.9,"fail_open":false}'; exit 0; }
case "$(cat "$FAKE/jev-verdict")" in
  fail) echo "jev: simulated outage" >&2; exit 1 ;;
  garbage) echo "not json at all"; exit 0 ;;
  v) printf '{"verdict":"%s","confidence":0.9,"fail_open":false}\n' "$(cat "$FAKE/jev-answer")" ;;
  *) printf '{"verdict":"%s","confidence":0.9,"fail_open":false}\n' "$(cat "$FAKE/jev-verdict")" ;;
esac
SH

  chmod +x "$fb/gh" "$fb/curl" "$fb/fm-spawn" "$fb/jev"

  # Default scenario: one bridge event for one open SOS ticket.
  set_bridge_events "$fd" 1 "$SOS_UUID" "$GH_ISSUE"
  set_gh_open_issues "$fd" "$GH_ISSUE" "$SOS_UUID"

  printf '%s\n' "$home|$fb|$fd"
}

set_bridge_events() { # <fakedir> <id> <uuid> <issue>
  local fd=$1 id=$2 uuid=$3 issue=$4
  cat > "$fd/bridge.json" <<EOF
{"events":[{"id":$id,"kind":"sos","dedupeKey":"$uuid","at":"2026-09-26T12:00:00.000Z","receivedAt":"2026-09-26T12:00:01.000Z","site":"covenant","payload":{"ticket":"${uuid%%-*}","gh_issue":$issue,"gh_issue_url":"https://github.com/ArcsHealth/Portal/issues/$issue"}}],"cursor":$id,"backlog":0}
EOF
}

set_bridge_empty() { # <fakedir>
  printf '{"events":[],"cursor":0,"backlog":0}\n' > "$1/bridge.json"
}

set_gh_open_issues() { # <fakedir> <issue> <uuid>
  local fd=$1 issue=$2 uuid=$3
  cat > "$fd/gh-list.json" <<EOF
[{"number":$issue,"url":"https://github.com/ArcsHealth/Portal/issues/$issue","title":"SOS: reported problem","body":"### SOS Voice Ticket\n- **SOS ID:** \`$uuid\`\n"}]
EOF
}

run_intake() { # <case-parts> <args...>
  local parts=$1
  shift
  local home fb fd
  home=${parts%%|*}
  fb=$(printf '%s' "$parts" | cut -d'|' -f2)
  fd=${parts##*|}
  FM_HOME="$home" \
  FM_ISSUE_FAKE_DIR="$fd" \
  FM_ISSUE_BRIDGE_URL="http://bridge.invalid:8791" \
  FM_ISSUE_TASKS="$TASKS_AXI" \
  FM_ISSUE_SPAWN="$fb/fm-spawn" \
  FM_ISSUE_BRIEF="$ROOT/bin/fm-brief.sh" \
  FM_ISSUE_WHEN="$ROOT/bin/fm-procevent-when.sh" \
  PATH="$fb:$PATH" \
    "$INTAKE" "$@"
}

task_state_of() { # <case-parts> [task-id]
  local parts=$1 id=${2:-$TASK_ID} home
  home=${parts%%|*}
  FM_HOME="$home" "$TASKS_AXI" show "$id" 2>/dev/null \
    | sed -n 's/^  state: //p' | head -1
}

task_present() { # <case-parts> [task-id]
  local parts=$1 id=${2:-$TASK_ID} home
  home=${parts%%|*}
  FM_HOME="$home" "$TASKS_AXI" show "$id" >/dev/null 2>&1
}

# count_of <fixed-string> <file>: matches in file, 0 when the file is absent.
count_of() {
  local n
  n=$(grep -cF -- "$1" "$2" 2>/dev/null) || true
  echo "${n:-0}"
}

test_decline_comments_once_even_when_the_close_fails() {
  local parts home fd out
  parts=$(setup_case decline-retry)
  home=${parts%%|*}
  fd=${parts##*|}
  printf 'not_supported\n' > "$fd/jev-verdict"

  out=$(run_intake "$parts" reconcile 2>&1) || fail "first reconcile failed: $out"
  assert_contains "$out" "failed: decline" "a failing close must be reported: $out"
  assert_equals "1" "$(count_of '**Not supported**' "$fd/comments.log")" \
    "the first pass posts exactly one decline comment"
  assert_equals "1" "$(count_of 'CLOSE-ATTEMPTED' "$fd/gh.log")" \
    "the first pass attempts the close once"

  out=$(run_intake "$parts" reconcile 2>&1) || fail "retry reconcile failed: $out"
  assert_equals "1" "$(count_of '**Not supported**' "$fd/comments.log")" \
    "a retry after a failed close must not re-comment: $(cat "$fd/comments.log" 2>/dev/null)"
  assert_equals "2" "$(count_of 'CLOSE-ATTEMPTED' "$fd/gh.log")" \
    "a retry must re-attempt only the close"

  : > "$fd/allow-close"
  out=$(run_intake "$parts" reconcile) || fail "closing reconcile failed: $out"
  assert_contains "$out" "declined=1" "the decline must complete: $out"
  assert_equals "1" "$(count_of '**Not supported**' "$fd/comments.log")" \
    "the completing pass adds no comment"
  assert_equals "done" "$(task_state_of "$parts")" "the declined row must close"

  out=$(run_intake "$parts" reconcile) || fail "post-decline replay failed: $out"
  assert_contains "$out" "declined=1" "the decided decline replays as handled: $out"
  assert_equals "1" "$(count_of '**Not supported**' "$fd/comments.log")" \
    "a post-decline replay adds no comment"
  assert_equals "3" "$(count_of 'CLOSE-ATTEMPTED' "$fd/gh.log")" \
    "a completed decline is never closed again"
  pass "a decline comments once and a failed close retries only the close"
}

test_event_without_a_url_keeps_row_and_cursor_aligned() {
  local parts home fd out
  parts=$(setup_case no-url)
  home=${parts%%|*}
  fd=${parts##*|}
  cat > "$fd/bridge.json" <<EOF
{"events":[{"id":1,"kind":"sos","dedupeKey":"$SOS_UUID","at":"2026-09-26T12:00:00.000Z","receivedAt":"2026-09-26T12:00:01.000Z","site":"covenant","payload":{"ticket":"${SOS_UUID%%-*}","gh_issue":$GH_ISSUE}}],"cursor":1,"backlog":0}
EOF
  printf '[]\n' > "$fd/gh-list.json"

  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "task_created=1" \
    "a url-less event must still create its row: $out"
  assert_equals "1" "$(cat "$home/state/fm-issue-intake.cursor")" \
    "the cursor must land on the event id, never reset"
  assert_contains "$(FM_HOME="$home" "$TASKS_AXI" show "$TASK_ID" 2>/dev/null)" \
    "GitHub issue: https://github.com/ArcsHealth/Portal/issues/$GH_ISSUE" \
    "an empty url must fall back to the canonical issue URL"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "the url-less event must dispatch exactly once"
  pass "an event without a url keeps the row body and cursor aligned"
}

test_one_github_issue_is_never_two_candidates() {
  local parts home fd out upper
  upper=$(printf '%s' "$SOS_UUID" | tr '[:lower:]' '[:upper:]')

  # (a) an uppercased bridge dedupeKey against the lowercase body marker.
  parts=$(setup_case keycase)
  home=${parts%%|*}
  fd=${parts##*|}
  set_bridge_events "$fd" 1 "$upper" "$GH_ISSUE"
  out=$(run_intake "$parts" reconcile) || fail "case reconcile failed: $out"
  assert_contains "$out" "task_created=1" \
    "an uppercased dedupeKey must merge with the lowercase marker: $out"
  assert_equals "1" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "one ticket must get exactly one dispatched comment"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "one ticket must spawn exactly once"
  if FM_HOME="$home" "$TASKS_AXI" show "fm-iss-$upper" >/dev/null 2>&1; then
    fail "the uppercase key minted a second row for one ticket"
  fi
  task_present "$parts" || fail "the lowercase row must own the ticket"

  # (b) a bridge event plus an open sos issue whose body carries no marker.
  parts=$(setup_case no-marker)
  home=${parts%%|*}
  fd=${parts##*|}
  cat > "$fd/gh-list.json" <<EOF
[{"number":$GH_ISSUE,"url":"https://github.com/ArcsHealth/Portal/issues/$GH_ISSUE","title":"SOS: reported problem","body":"### SOS Voice Ticket\ntranscribed report with no SOS marker"}]
EOF
  out=$(run_intake "$parts" reconcile) || fail "marker-less reconcile failed: $out"
  assert_contains "$out" "task_created=1" \
    "an event plus a marker-less issue is one ticket: $out"
  assert_equals "1" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "the merged ticket must get exactly one dispatched comment"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "the merged ticket must spawn exactly once"
  if FM_HOME="$home" "$TASKS_AXI" show "fm-iss-gh-issue-$GH_ISSUE" >/dev/null 2>&1; then
    fail "the fallback key minted a second row for one ticket"
  fi
  pass "one GitHub issue is never split into two candidates"
}

test_stale_pre_rename_watch_is_retired_and_rearmed() {
  local parts home fd out
  parts=$(setup_case stale-watch)
  home=${parts%%|*}
  fd=${parts##*|}

  cat > "$fd/fm-sos-intake.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fd/fm-sos-intake.sh"
  FM_HOME="$home" "$ROOT/bin/fm-procevent-when.sh" arm "sos-$GH_ISSUE" \
    --condition "$fd/fm-sos-intake.sh" watch-condition "$GH_ISSUE" \
    --action "$fd/fm-sos-intake.sh" watch-fire "$GH_ISSUE" "$SOS_UUID" >/dev/null \
    || fail "fixture arm of the pre-rename watch failed"
  # The spec is the watch's persisted, hash-bound state; a pre-rename one
  # names the retired script in its argv.
  assert_grep "fm-sos-intake.sh" "$home/state/when/when-sos-$GH_ISSUE.spec" \
    "fixture must start from a spec bound to the retired script"

  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_present "$home/state/when/when-sos-$GH_ISSUE.spec" "the watch must stay armed"
  assert_grep "fm-issue-intake.sh" "$home/state/when/when-sos-$GH_ISSUE.spec" \
    "reconcile must re-arm the watch against the renamed script"
  assert_no_grep "fm-sos-intake.sh" "$home/state/when/when-sos-$GH_ISSUE.spec" \
    "the retired script path must be gone from the watch"
  assert_equals "1" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "the ordinary dispatch path still comments once"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "the ordinary dispatch path still spawns once"
  pass "a stale pre-rename watch is retired and re-armed against the renamed script"
}

test_two_pass_marker_less_ticket_stays_one_ticket() {
  local parts home fd out
  parts=$(setup_case two-pass-marker-less)
  home=${parts%%|*}
  fd=${parts##*|}
  cat > "$fd/gh-list.json" <<EOF
[{"number":$GH_ISSUE,"url":"https://github.com/ArcsHealth/Portal/issues/$GH_ISSUE","title":"SOS: reported problem","body":"### SOS Voice Ticket\ntranscribed report with no SOS marker"}]
EOF

  # Pass 1: the bridge event and the open marker-less issue fold into one
  # candidate keyed on the event's dedupeKey.
  out=$(run_intake "$parts" reconcile) || fail "pass 1 failed: $out"
  assert_contains "$out" "task_created=1" "pass 1 must create one row: $out"
  assert_contains "$out" "dispatched=1" "pass 1 must dispatch: $out"

  # Pass 2: the bridge is drained; only the GH-heal axis offers the same
  # ticket, under the gh-issue fallback key.
  set_bridge_empty "$fd"
  out=$(run_intake "$parts" reconcile) || fail "pass 2 failed: $out"
  assert_contains "$out" "task_created=0" "pass 2 must not mint a second row: $out"
  assert_contains "$out" "dispatched=0" "pass 2 must not re-dispatch: $out"
  assert_equals "1" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "one dispatched comment across both passes"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "one spawn across both passes"
  assert_equals "1" "$(count_of 'jev verdict' "$fd/jev.log")" \
    "one verdict across both passes: $(cat "$fd/jev.log" 2>/dev/null)"
  task_present "$parts" || fail "the uuid row must own the ticket"
  if FM_HOME="$home" "$TASKS_AXI" show "fm-iss-gh-issue-$GH_ISSUE" >/dev/null 2>&1; then
    fail "the heal pass must not mint a gh-issue row for the same ticket"
  fi
  pass "a marker-less ticket stays one ticket across the event and heal passes"
}

test_failed_spawn_is_retried_and_never_ledgered() {
  local parts home fd out ledger
  parts=$(setup_case spawn-fail)
  home=${parts%%|*}
  fd=${parts##*|}
  ledger="$home/state/fm-issue-intake.log"
  touch "$fd/spawn-fail"

  out=$(run_intake "$parts" reconcile 2>&1) || fail "reconcile failed: $out"
  assert_contains "$out" "failed: dispatch" "the spawn failure must be reported: $out"
  assert_contains "$out" "dispatched=0" "a failed spawn must not count as dispatched: $out"
  assert_equals "0" "$(count_of 'dispatch key=' "$ledger")" \
    "a failed spawn must never be ledgered as dispatched"
  assert_absent "$home/state/fm-issue-intake.cursor" \
    "the failed dispatch must block the cursor"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "the spawn was attempted once"

  rm -f "$fd/spawn-fail"
  out=$(run_intake "$parts" reconcile 2>&1) || fail "retry failed: $out"
  assert_contains "$out" "dispatched=1" "the ticket must dispatch on retry: $out"
  assert_equals "1" "$(count_of 'dispatch key=' "$ledger")" \
    "exactly one dispatch record after the retry"
  assert_equals "2" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "one failed attempt plus one real spawn"
  assert_equals "1" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "the retry must not re-comment"
  assert_equals "1" "$(cat "$home/state/fm-issue-intake.cursor")" \
    "the cursor must advance once the dispatch lands"
  pass "a failed spawn is retried and never ledgered as dispatched"
}

test_watch_fire_never_captain_closes_a_declined_issue() {
  local parts home fd out ledger
  parts=$(setup_case decline-watch)
  home=${parts%%|*}
  fd=${parts##*|}
  ledger="$home/state/fm-issue-intake.log"

  # An ops run arms the watch and dispatches; a later gate-on run declines
  # and closes the same ticket.
  out=$(run_intake "$parts" reconcile --no-verdict) || fail "ops pass failed: $out"
  assert_contains "$out" "dispatched=1" "the ops pass must dispatch: $out"
  printf 'not_supported\n' > "$fd/jev-verdict"
  : > "$fd/allow-close"
  out=$(run_intake "$parts" reconcile) || fail "decline pass failed: $out"
  assert_contains "$out" "declined=1" "the decline must land: $out"

  # The tolerated row-close failure leaves no task-closed record behind.
  grep -v '^task-closed key=' "$ledger" > "$ledger.tmp"
  mv "$ledger.tmp" "$ledger"

  out=$(run_intake "$parts" watch-fire "$GH_ISSUE" "$SOS_UUID") || fail "watch-fire failed: $out"
  assert_contains "$out" "declined-recorded" \
    "watch-fire must recognize the decline record itself: $out"
  assert_no_grep "Closed by the captain" "$fd/comments.log" \
    "a declined issue must never get a captain-closed comment"
  assert_equals "2" "$(count_of '' "$fd/comments.log")" \
    "only the dispatched and declined comments exist"
  assert_no_grep "closed key=" "$ledger" \
    "the decline never authorizes the reporter handoff marker"
  pass "watch-fire never captain-closes an issue intake declined"
}

test_reconcile_creates_one_task_comment_watch_and_dispatch() {
  local parts home fd out
  parts=$(setup_case basic)
  home=${parts%%|*}
  fd=${parts##*|}

  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "task_created=1" "reconcile should report one created task: $out"
  assert_contains "$out" "dispatched=1" "reconcile should report one dispatch: $out"

  # The row id IS the SOS UUID key: the idempotency contract made literal.
  task_present "$parts" || fail "task row $TASK_ID missing"
  assert_equals "queued" "$(task_state_of "$parts")" "a fresh task row must await dispatch"

  # One dispatched lifecycle comment on the GitHub issue.
  assert_equals "1" "$(count_of '' "$fd/comments.log")" \
    "expected exactly one comment, got: $(cat "$fd/comments.log" 2>/dev/null)"
  assert_contains "$(cat "$fd/comments.log")" "Issue intake" "the intake's comment must identify itself"
  assert_contains "$(cat "$fd/comments.log")" "$TASK_ID" "the comment must name the task row"
  assert_contains "$(cat "$fd/comments.log")" "never closes it" "the comment must state the no-self-close rule"

  # One armed close watch (real fm-procevent-when.sh spec + trust record).
  assert_present "$home/state/when/when-sos-$GH_ISSUE.spec" "close watch spec missing"
  assert_present "$home/state/when/when-sos-$GH_ISSUE.trust" "close watch trust record missing"

  # One spawn, on the auto-dispatch contract, with a filled brief.
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" "expected exactly one spawn"
  assert_contains "$(cat "$fd/spawn.log")" "$TASK_ID" "spawn must name the ticket task id"
  assert_contains "$(cat "$fd/spawn.log")" "--mode no-mistakes" "spawn must carry the delivery mode"
  assert_grep "Resolve the staff SOS reported in ArcsHealth/Portal#$GH_ISSUE" \
    "$home/data/$TASK_ID/brief.md" "brief captain intent must name the issue"
  assert_no_grep "{TASK}" "$home/data/$TASK_ID/brief.md" "brief must carry no placeholders"
  assert_no_grep "{FIRSTMATE_SPEC}" "$home/data/$TASK_ID/brief.md" "brief must carry no placeholders"
  assert_grep "NEVER run \`gh issue close\`" "$home/data/$TASK_ID/brief.md" \
    "the worker brief must forbid closing the issue"

  # The cursor landed on the event id, and the loop never closed the issue.
  assert_equals "1" "$(cat "$home/state/fm-issue-intake.cursor")" "cursor must advance to the event id"
  assert_no_grep "CLOSE-ATTEMPTED" "$fd/gh.log" "the intake must never close a GitHub issue"
  pass "reconcile creates one task row, comment, watch, and dispatch"
}

test_reconcile_is_idempotent_across_replays_and_lost_cursors() {
  local parts out
  parts=$(setup_case replay)
  run_intake "$parts" reconcile >/dev/null || fail "first reconcile failed"

  # A second pass over a drained bridge changes nothing.
  set_bridge_empty "${parts##*|}"
  out=$(run_intake "$parts" reconcile) || fail "second reconcile failed: $out"
  assert_contains "$out" "task_created=0" "second pass must create no row: $out"
  assert_contains "$out" "dispatched=0" "second pass must not re-dispatch: $out"

  # Lose the cursor entirely and replay the same event: the SOS UUID row id is
  # the idempotency anchor, so work is never done twice.
  rm -f "${parts%%|*}/state/fm-issue-intake.cursor"
  set_bridge_events "${parts##*|}" 1 "$SOS_UUID" "$GH_ISSUE"
  out=$(run_intake "$parts" reconcile) || fail "replay reconcile failed: $out"
  assert_contains "$out" "task_created=0" "replay must create no second row: $out"
  assert_contains "$out" "dispatched=0" "replay must not re-dispatch: $out"

  task_present "$parts" || fail "replay lost the task row"
  assert_equals "1" "$(count_of 'Issue intake' "${parts##*|}/comments.log")" \
    "replay must not double-comment"
  assert_equals "1" "$(count_of 'fm-spawn' "${parts##*|}/spawn.log")" \
    "replay must never double-dispatch"
  pass "reconcile is idempotent across replays and lost cursors"
}

test_lost_event_is_healed_from_github() {
  local parts out
  parts=$(setup_case heal)
  # No event at all (pre-bridge ticket, or a bridge that lost the POST): the
  # open sos-labeled issue alone is enough to dispatch.
  set_bridge_empty "${parts##*|}"
  out=$(run_intake "$parts" reconcile) || fail "heal reconcile failed: $out"
  assert_contains "$out" "task_created=1" "the GH heal path must create the row: $out"

  out=$(run_intake "$parts" reconcile) || fail "heal re-run failed: $out"
  assert_contains "$out" "task_created=0" "the heal path must be idempotent: $out"
  assert_equals "1" "$(count_of 'Issue intake' "${parts##*|}/comments.log")" \
    "the heal path must not double-comment"
  pass "a lost bridge event is healed from GitHub and never double-dispatches"
}

test_watch_condition_never_reads_a_failure_as_closed() {
  local parts fd rc
  parts=$(setup_case condition)
  fd=${parts##*|}

  run_intake "$parts" watch-condition "$GH_ISSUE"
  rc=$?
  expect_code 1 "$rc" "an OPEN issue must be a clean false"

  echo '{"state":"CLOSED"}' > "$fd/gh-state-$GH_ISSUE"
  run_intake "$parts" watch-condition "$GH_ISSUE"
  rc=$?
  expect_code 0 "$rc" "a CLOSED issue must be a clean true"

  echo "state=$(date +%s)" > "$fd/gh-state-$GH_ISSUE"
  run_intake "$parts" watch-condition "$GH_ISSUE"
  rc=$?
  expect_code 2 "$rc" "an unparseable answer must never count as closed"

  touch "$fd/gh-broken"
  run_intake "$parts" watch-condition "$GH_ISSUE"
  rc=$?
  expect_code 2 "$rc" "a gh failure must never count as closed"
  rm -f "$fd/gh-broken"
  pass "watch-condition is closed-only and fails closed"
}

test_watch_fire_comments_closes_the_task_and_never_the_issue() {
  local parts home fd out
  parts=$(setup_case fire)
  home=${parts%%|*}
  fd=${parts##*|}
  run_intake "$parts" reconcile >/dev/null || fail "setup reconcile failed"

  out=$(run_intake "$parts" watch-fire "$GH_ISSUE" "$SOS_UUID") || fail "watch-fire failed: $out"
  assert_contains "$out" "captain-closed" "watch-fire must report the close"
  assert_contains "$(cat "$fd/comments.log")" "Closed by the captain" \
    "watch-fire must comment the close on the issue"

  assert_equals "done" "$(task_state_of "$parts")" \
    "watch-fire must close the task row, not the issue"

  assert_no_grep "CLOSE-ATTEMPTED" "$fd/gh.log" "watch-fire must never close the GitHub issue"

  out=$(run_intake "$parts" watch-fire "$GH_ISSUE" "$SOS_UUID") || fail "re-run failed: $out"
  assert_contains "$out" "already-closed-recorded" "a manual re-run must be a no-op"
  assert_equals "1" "$(count_of 'Closed by the captain' "$fd/comments.log")" \
    "the close comment must post exactly once"

  # Regression: a replayed event after the task closed must not mint a second
  # row, and must not reopen the closed one.
  rm -f "$home/state/fm-issue-intake.cursor"
  set_bridge_events "$fd" 1 "$SOS_UUID" "$GH_ISSUE"
  printf '[]\n' > "$fd/gh-list.json"
  out=$(run_intake "$parts" reconcile) || fail "post-close replay failed: $out"
  assert_contains "$out" "task_created=0" "a closed row must still absorb the replay: $out"
  assert_equals "done" "$(task_state_of "$parts")" \
    "a replayed add must never reopen a closed row"
  pass "watch-fire comments once, closes the task row, and never the issue"
}

test_comment_transitions_are_canonical_and_bounded() {
  local parts fd out rc
  parts=$(setup_case comments)
  fd=${parts##*|}

  out=$(run_intake "$parts" comment "$GH_ISSUE" fix-up "PR https://github.com/ArcsHealth/Portal/pull/1") \
    || fail "comment failed: $out"
  assert_contains "$(cat "$fd/comments.log")" "Fix up" "fix-up comment must carry the canonical label"
  assert_contains "$(cat "$fd/comments.log")" "pull/1" "the note must ride along"

  run_intake "$parts" comment "$GH_ISSUE" nonsense
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown transition must be refused"
  assert_equals "1" "$(count_of '' "$fd/comments.log")" "a refused transition must not post"

  for t in deployed verified repro-confirmed; do
    out=$(run_intake "$parts" comment "$GH_ISSUE" "$t") || fail "comment $t failed: $out"
  done
  assert_equals "4" "$(count_of '' "$fd/comments.log")" "each transition posts once"
  assert_no_grep "CLOSE-ATTEMPTED" "$fd/gh.log" "comments must never close the issue"
  pass "transition comments are canonical, bounded, and never close the issue"
}

test_dry_run_changes_nothing() {
  local parts out
  parts=$(setup_case dry)
  out=$(run_intake "$parts" reconcile --dry-run) || fail "dry-run failed: $out"
  assert_contains "$out" "would-create" "dry-run must report the plan: $out"
  if task_present "$parts"; then fail "dry-run must create no task row"; fi
  assert_absent "${parts%%|*}/state/fm-issue-intake.cursor" "dry-run must not move the cursor"
  [ ! -f "${parts##*|}/comments.log" ] || fail "dry-run must post no comment"
  [ ! -f "${parts##*|}/spawn.log" ] || fail "dry-run must not dispatch"
  pass "dry-run reports the plan and changes nothing"
}

test_legacy_fm_sos_rows_stay_authoritative() {
  local parts home fd out
  parts=$(setup_case legacy)
  home=${parts%%|*}
  fd=${parts##*|}

  # A row minted before the fm-sos -> fm-iss rename already owns this ticket.
  FM_HOME="$home" "$TASKS_AXI" add "fm-sos-$SOS_UUID" "legacy row for the ticket" \
    --kind ship --repo portal --priority 1 >/dev/null || fail "legacy row setup failed"

  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "task_created=0" "the legacy row must be reused, not duplicated: $out"
  assert_contains "$(cat "$fd/comments.log")" "fm-sos-$SOS_UUID" \
    "the comment must name the pre-rename row"
  task_present "$parts" "fm-sos-$SOS_UUID" || fail "legacy row disappeared"
  if FM_HOME="$home" "$TASKS_AXI" show "fm-iss-$SOS_UUID" >/dev/null 2>&1; then
    fail "the rename minted a second row for one ticket"
  fi
  pass "legacy fm-sos rows stay authoritative across the rename"
}

test_verdict_declines_a_by_design_request() {
  local parts home fd out
  parts=$(setup_case decline)
  home=${parts%%|*}
  fd=${parts##*|}
  printf 'not_supported\n' > "$fd/jev-verdict"
  : > "$fd/allow-close"

  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "declined=1" "the decline must be counted: $out"
  assert_contains "$(cat "$fd/comments.log")" "**Not supported**" "the reporter must get the decline"
  assert_contains "$(cat "$fd/gh.log")" "CLOSE-ATTEMPTED" "the decline closes the issue"
  assert_contains "$(cat "$fd/edit.log" 2>/dev/null)" "not-supported" \
    "the not-supported label must be applied"
  assert_equals "done" "$(task_state_of "$parts")" "the declined row must be closed"
  [ ! -f "$fd/spawn.log" ] || fail "a declined ticket must never spawn"
  [ ! -f "$home/state/when/when-sos-$GH_ISSUE.spec" ] || fail "a declined ticket must not arm a watch"

  # Replay: one decline, one comment, no second close attempt.
  : > "$fd/gh.log"
  out=$(run_intake "$parts" reconcile) || fail "replay failed: $out"
  assert_contains "$out" "declined=1" "the replay still counts it once: $out"
  assert_equals "1" "$(count_of "**Not supported**" "$fd/comments.log")" \
    "replay must not re-decline: $(cat "$fd/comments.log" 2>/dev/null)"
  assert_no_grep "CLOSE-ATTEMPTED" "$fd/gh.log" "replay must not close again"
  pass "a by-design request is declined, closed, and never re-declined"
}

test_verdict_holds_uncertain_tickets_for_the_captain() {
  local parts home fd out
  parts=$(setup_case hold)
  home=${parts%%|*}
  fd=${parts##*|}
  printf 'captain_review\n' > "$fd/jev-verdict"

  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "review=1" "the hold must be counted: $out"
  assert_contains "$out" "held for the captain" "the hold must be visible"
  [ ! -f "$fd/comments.log" ] || fail "a held ticket must not comment"
  assert_no_grep "CLOSE-ATTEMPTED" "$fd/gh.log" "a held ticket must not close"
  [ ! -f "$fd/spawn.log" ] || fail "a held ticket must never spawn"
  assert_equals "queued" "$(task_state_of "$parts")" "the held row stays queued for the captain"
  pass "an uncertain ticket is held for the captain and never acted on"
}

test_verdict_failure_fails_open_not_closed() {
  local parts fd out
  parts=$(setup_case failopen)
  fd=${parts##*|}
  printf 'fail\n' > "$fd/jev-verdict"
  : > "$fd/allow-close"

  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "review=1" "a broken classifier must hold, not decide: $out"
  assert_no_grep "CLOSE-ATTEMPTED" "$fd/gh.log" "a broken classifier must never close"
  [ ! -f "$fd/spawn.log" ] || fail "a broken classifier must never spawn"
  pass "verdict failure fails open to captain review"
}

test_verdict_is_decided_once() {
  local parts fd out calls
  parts=$(setup_case once)
  fd=${parts##*|}
  printf 'supported_bug\n' > "$fd/jev-verdict"

  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "dispatched=1" "supported tickets still dispatch: $out"
  out=$(run_intake "$parts" reconcile) || fail "replay failed: $out"
  calls=$(count_of 'jev verdict' "$fd/jev.log")
  assert_equals "1" "$calls" "the verdict must be decided exactly once: $(cat "$fd/jev.log" 2>/dev/null)"
  pass "the verdict is decided once and ledgered across replays"
}

test_reconcile_creates_one_task_comment_watch_and_dispatch
test_reconcile_is_idempotent_across_replays_and_lost_cursors
test_lost_event_is_healed_from_github
test_watch_condition_never_reads_a_failure_as_closed
test_watch_fire_comments_closes_the_task_and_never_the_issue
test_comment_transitions_are_canonical_and_bounded
test_dry_run_changes_nothing
test_legacy_fm_sos_rows_stay_authoritative
test_verdict_declines_a_by_design_request
test_verdict_holds_uncertain_tickets_for_the_captain
test_verdict_failure_fails_open_not_closed
test_verdict_is_decided_once
test_decline_comments_once_even_when_the_close_fails
test_event_without_a_url_keeps_row_and_cursor_aligned
test_one_github_issue_is_never_two_candidates
test_stale_pre_rename_watch_is_retired_and_rearmed
test_two_pass_marker_less_ticket_stays_one_ticket
test_failed_spawn_is_retried_and_never_ledgered
test_watch_fire_never_captain_closes_a_declined_issue
