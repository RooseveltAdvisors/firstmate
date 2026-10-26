#!/usr/bin/env bash
# tests/fm-never-prune.test.sh - the data/.never-prune exception class
# (bin/fm-backlog-transition-lib.sh). A preservation directory listed in
# <data>/.never-prune must survive its row's close byte-identical, with a
# durable `never-prune honored: <path>` line recorded where the marker replay
# shows it; an unlisted directory stays cleanup-eligible. Incident evidence:
# the 2026-10-24/25 backlog-close cleanup wiped three tasks' preservation sets
# (bead wiseman-os83), including a sole-copy git bundle.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || {
  echo "skip: tasks-axi not found (close-marker replay closes rows through it)"
  exit 0
}

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$ROOT/bin/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$ROOT/bin/fm-backlog-transition-lib.sh"

unset TASKS_AXI_BACKEND || :

TMP_ROOT=$(fm_test_tmproot fm-never-prune)

# --- match semantics --------------------------------------------------------

MATCH_HOME="$TMP_ROOT/match-home"
mkdir -p "$MATCH_HOME/data/fm-keep" "$MATCH_HOME/data/fm-keep-2" \
  "$MATCH_HOME/data/fm-preserve-a" "$MATCH_HOME/data/fm-drop"
cat > "$MATCH_HOME/data/.never-prune" <<'EOF'
# preservation exception class, one entry per line

data/fm-keep
data/fm-preserve-*
EOF

fm_never_prune_match "$MATCH_HOME/data" "$MATCH_HOME/data/fm-keep" \
  || fail "a data/<name> entry should match the resolved absolute path"
pass "never-prune: a data/<name> entry matches its absolute candidate"

fm_never_prune_match "$MATCH_HOME/data" "$MATCH_HOME/data/fm-preserve-a" \
  || fail "a data/<glob> entry should match a globbed candidate"
pass "never-prune: a shell glob entry matches"

if fm_never_prune_match "$MATCH_HOME/data" "$MATCH_HOME/data/fm-drop"; then
  fail "an unlisted directory matched the never-prune list"
fi
if fm_never_prune_match "$MATCH_HOME/data" "$MATCH_HOME/data/fm-keep-2/sub"; then
  fail "a subdirectory of a listed directory matched (entries are exact, not prefixes)"
fi
pass "never-prune: unlisted and merely-nested paths do not match"

printf '%s\n' "$MATCH_HOME/data/fm-keep-2" >> "$MATCH_HOME/data/.never-prune"
fm_never_prune_match "$MATCH_HOME/data" "$MATCH_HOME/data/fm-keep-2" \
  || fail "an absolute entry should match its own path"
pass "never-prune: an absolute entry matches"

if fm_never_prune_match "$MATCH_HOME/no-such-data" "$MATCH_HOME/data/fm-keep"; then
  fail "a missing .never-prune list matched"
fi
pass "never-prune: an absent list protects nothing and fails open to cleanup"

# --- close-marker replay over a listed preservation directory ---------------

# A home with a queued row, a pending close marker in the shape teardown
# writes, and a task data directory holding "preservation" content.
make_close_fixture() {  # <case-dir> <id>
  local dir=$1 id=$2
  mkdir -p "$dir/state" "$dir/data/$id"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  cat > "$dir/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  ( cd "$dir" && tasks-axi add "$id" "item for $id" --kind ship >/dev/null ) \
    || fail "fixture: could not seed the backlog row for $id"
  printf 'id=%s\ndata=%s\nspawn_gen=s1\ncleanup_incomplete=0\n' \
    "$id" "$dir/data" > "$dir/state/$id.backlog-close"
}

LISTED_DIR="$TMP_ROOT/listed"
LISTED_ID=nprune-listed-b7
make_close_fixture "$LISTED_DIR" "$LISTED_ID"
printf 'preservation manifest: sole-copy bundle\n' \
  > "$LISTED_DIR/data/$LISTED_ID/preservation-manifest.txt"
printf 'fake bundle bytes %s\n' "$LISTED_ID" > "$LISTED_DIR/data/$LISTED_ID/sole-copy.bundle"
printf 'data/%s\n' "$LISTED_ID" > "$LISTED_DIR/data/.never-prune"
before_listed=$(find "$LISTED_DIR/data/$LISTED_ID" -type f -exec sha256sum {} + | sort)

# The replay reports through an output global, so it must run in this shell;
# its visible output goes to a file the assertions then read.
fm_backlog_close_marker_replay "$LISTED_DIR/state" \
  "$LISTED_DIR/state/$LISTED_ID.backlog-close" "$LISTED_DIR/data" \
  > "$LISTED_DIR/replay.out" \
  || fail "the listed close marker did not replay: $FM_BACKLOG_TRANSITION_ERROR"
out=$(cat "$LISTED_DIR/replay.out")
assert_equals closed "$FM_BACKLOG_CLOSE_REPLAY_RESULT" \
  "the listed close marker should replay to a normal row close"
after_listed=$(find "$LISTED_DIR/data/$LISTED_ID" -type f -exec sha256sum {} + | sort)
assert_equals "$before_listed" "$after_listed" \
  "a never-prune-listed directory changed across its row's close"
assert_contains "$out" "never-prune honored: $LISTED_DIR/data/$LISTED_ID" \
  "the replay did not show the honored never-prune exception"
assert_grep "never-prune honored: $LISTED_DIR/data/$LISTED_ID" \
  "$LISTED_DIR/state/never-prune.log" \
  "the honored exception was not recorded durably"
assert_absent "$LISTED_DIR/state/$LISTED_ID.backlog-close" \
  "a replayed close left its marker behind"
# Close probe: row membership in the Done section of the canonical markdown
# store, never a tasks-axi render. The backend records a closed row as a line
# holding the id under the `## Done` heading the fixture seeds; `tasks-axi
# show` output differs between installs (the B1 host render prints no
# whitespace-pinned "state:" line) and no structured `show --json` exists.
awk -v id="$LISTED_ID" '
  /^##[[:space:]]/ { in_done = ($0 ~ /^##[[:space:]]+Done[[:space:]]*$/) }
  in_done && index($0, id) { found = 1 }
  END { exit(found ? 0 : 1) }
' "$LISTED_DIR/data/backlog.md" \
  || fail "the listed row did not close"
pass "never-prune: a listed preservation directory survives its row's close byte-identical"

# --- negative case: an unlisted target still cleans up ----------------------

PLAIN_DIR="$TMP_ROOT/plain"
PLAIN_ID=nprune-plain-b7
make_close_fixture "$PLAIN_DIR" "$PLAIN_ID"
printf 'scratch\n' > "$PLAIN_DIR/data/$PLAIN_ID/scratch.txt"
printf 'data/%s\n' "$LISTED_ID" > "$PLAIN_DIR/data/.never-prune"

fm_backlog_close_marker_replay "$PLAIN_DIR/state" \
  "$PLAIN_DIR/state/$PLAIN_ID.backlog-close" "$PLAIN_DIR/data" \
  > "$PLAIN_DIR/replay.out" \
  || fail "the unlisted close marker did not replay: $FM_BACKLOG_TRANSITION_ERROR"
out=$(cat "$PLAIN_DIR/replay.out")
assert_equals closed "$FM_BACKLOG_CLOSE_REPLAY_RESULT" \
  "the unlisted close marker should replay to a normal row close"
assert_not_contains "$out" "never-prune honored" \
  "an unlisted close recorded a never-prune honor"
[ ! -e "$PLAIN_DIR/state/never-prune.log" ] \
  || fail "an unlisted close left a never-prune log"
# The guard admits the ordinary cleanup the close makes eligible: the caller
# deletes, and nothing refuses.
if fm_never_prune_match "$PLAIN_DIR/data" "$PLAIN_DIR/data/$PLAIN_ID"; then
  fail "an unlisted task directory matched the never-prune list"
fi
rm -rf -- "$PLAIN_DIR/data/$PLAIN_ID"
assert_absent "$PLAIN_DIR/data/$PLAIN_ID" \
  "an unlisted task directory refused ordinary cleanup"
pass "never-prune: an unlisted directory closes without an honor and still cleans up"

# --- teardown wiring: the status-archive prune runs the same guard ----------

# bin/fm-teardown.sh is a script, not a sourceable library, so pin the wiring
# directly: teardown_prune_status_archives must consult the never-prune list
# before it deletes anything under a data/<task> directory.
prune_body=$(sed -n '/^teardown_prune_status_archives()/,/^}/p' "$ROOT/bin/fm-teardown.sh")
# shellcheck disable=SC2016 # The pinned wiring text is matched literally.
assert_contains "$prune_body" 'fm_never_prune_match "$DATA" "$dir"' \
  "teardown_prune_status_archives does not consult data/.never-prune"
assert_contains "$prune_body" "fm_never_prune_record" \
  "teardown_prune_status_archives skips a listed directory without recording the honor"
pass "never-prune: teardown's status-archive prune honors data/.never-prune"

printf 'fm-never-prune: all tests passed\n'
