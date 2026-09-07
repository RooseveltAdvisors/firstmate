#!/usr/bin/env bash
# Behavior tests for the spawn-time beads assignee stamp (captain 2026-09-07:
# assign every spawned worker - crewmate or secondmate - its backlog bead at
# task creation time, via the existing `bd assign`).
#
# bin/fm-backlog-transition-lib.sh's fm_beads_assign owns the mechanics and
# bin/fm-spawn.sh stamps the assignee at its success commit point. These tests
# drive the real spawn script against fixture homes and a stubbed bd, and
# assert the recorded bd calls and the spawn outcome:
#
#   beads home     a crewmate spawn stamps `bd assign <id> <id>` against the
#                  configured graph path, resolved against the backlog root;
#   markdown home  the stamp skips quietly - no bd call at all;
#   missing bead   a secondmate spawn (no backlog row of its own) skips
#                  quietly - the spawn still succeeds with no warning;
#   assign failure a crewmate spawn survives a failed stamp (best-effort) and
#                  says so on stderr;
#   binary absent  a [beads] binary that is not on PATH skips quietly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# An exported TASKS_AXI_BACKEND would outrank each case's .tasks.toml fixture
# in fm_tasks_axi_backend, so the backend cases must start from a clean slate.
# The herdr markers come from a firstmate actually running inside herdr; the
# secondmate cases below pin the tmux reference backend instead.
unset TASKS_AXI_BACKEND HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH HERDR_PANE_ID || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-beads-assign)

command -v tasks-axi >/dev/null 2>&1 || {
  printf 'ok - skipped (tasks-axi is not installed; the spawn dispatch transition is inert without it)\n'
  exit 0
}

# --- fixture ----------------------------------------------------------------

# A home with a real backlog, a real project clone with an origin, a pooled
# worktree, and stubs for every tool the spawn path shells out to. Shared
# shape with tests/fm-backlog-atomicity.test.sh's make_home.
make_home() {  # <name> <task-id>
  local name=$1 id=$2 case_dir home fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' claude > "$home/config/crew-harness"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$home/data/backlog.md"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the spawn-time beads assignee stamp for $id.

## Firstmate spec
Verify the spawn stamps the assignee.

# Definition of done
Delivery contract: mode=no-mistakes
EOF

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh gh-axi no-mistakes

  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  git -C "$case_dir/project" worktree add --quiet -b pooled "$case_dir/wt"

  printf '%s\n' "$case_dir"
}

home_of() { printf '%s/home\n' "$1"; }

add_item() {  # <case-dir> <id>
  tasks-axi add "$2" "item for $2" --kind ship --file "$(home_of "$1")/data/backlog.md" >/dev/null
}

# A tasks-axi stub for a Beads home: records its calls, passes the version and
# feature probes, and answers the row probe for exactly the fixture id without
# ever needing a real beads graph. Shared shape with
# tests/fm-backlog-atomicity.test.sh's make_beads_tasks_axi_stub.
make_beads_tasks_axi_stub() {  # <case-dir> <id>
  local case_dir=$1 id=$2
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/tasks-axi-calls"
case "\${1:-}" in
  --version)
    printf '%s\n' '0.2.5'
    ;;
  update)
    [ "\${2:-}" = --help ] || exit 1
    printf '%s\n' '--archive-body'
    ;;
  mv)
    [ "\${2:-}" = --help ] || exit 1
    printf '%s\n' 'usage: tasks-axi mv [<id>...]'
    ;;
  show)
    [ "\${2:-}" = "$id" ] || exit 1
    printf '%s\n' 'task:'
    printf '  id: %s\n' "$id"
    printf '%s\n' '  state: in_flight' '  held: no' '  blocked: no'
    ;;
  *)
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

write_beads_toml() {  # <case-dir> [extra-lines...]
  local case_dir=$1
  shift
  { printf '%s\n' 'backend = "beads"' '[beads]' 'path = ".beads"' 'prefix = "fm"'
    [ $# -eq 0 ] || printf '%s\n' "$@"
  } > "$(home_of "$case_dir")/.tasks.toml"
}

# A bd stub that records every invocation with its BEADS_DIR and exits with a
# fixed code for `assign` (0 unless the case overrides it).
make_bd_stub() {  # <case-dir> [assign-exit-code]
  local case_dir=$1 rc=${2:-0}
  local log="$case_dir/bd-calls"
  cat > "$case_dir/fakebin/bd" <<SH
#!/usr/bin/env bash
printf '%s\n' "BEADS_DIR=\${BEADS_DIR:-unset} \$*" >> "$log"
[ "\${1:-}" = assign ] || exit 0
exit $rc
SH
  chmod +x "$case_dir/fakebin/bd"
}

bd_calls() {  # <case-dir>
  cat "$1/bd-calls" 2>/dev/null
}

run_ship_spawn() {  # <case-dir> <id>
  local case_dir=$1 id=$2
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), so it runs against a throwaway HOME.
  mkdir -p "$case_dir/user-home"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" HOME="$case_dir/user-home" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$case_dir/wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off 2>&1
}

# Runs the same spawn again as a relaunch (identity comes from the task's own
# record, so the id alone is enough). The fresh spawn's dumb tmux stub leaves
# no inventory, so the relaunch's agent-free probe reads 'missing'; this stub
# answers the probe with an inventory entry for the task's recorded window and
# an idle shell foreground, the classification bin/backends/tmux.sh accepts as
# positively agent-free.
run_ship_relaunch() {  # <case-dir> <id> <window-name>
  local case_dir=$1 id=$2 window=$3
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '%s\n' "$FM_FAKE_TMUX_WINDOW_NAME"; exit 0 ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf '%s\n' 'bash'; exit 0 ;;
      *pane_current_path*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  mkdir -p "$case_dir/user-home"
  FM_FAKE_TMUX_WINDOW_NAME="$window" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" HOME="$case_dir/user-home" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$case_dir/wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$id" --relaunch 2>&1
}

# Runs fm-spawn.sh in secondmate mode against a minimal seeded secondmate home
# (validate_firstmate_home_for_spawn needs the seed marker, AGENTS.md, bin/,
# and a charter). Shared shape with tests/fm-secondmate-harness.test.sh.
run_secondmate_spawn() {  # <case-dir> <id>
  local case_dir=$1 id=$2 home sm
  home=$(home_of "$case_dir")
  sm="$case_dir/$id"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  mkdir -p "$case_dir/user-home"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_SPAWN_NO_GUARD=1 TMUX='' CLAUDECODE=1 \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$id" "$sm" --secondmate 2>&1
}

# --- cases ------------------------------------------------------------------

test_beads_ship_spawn_stamps_the_assignee() {
  local case_dir id out
  id=beads-assign-b1
  case_dir=$(make_home assign-ok "$id")
  write_beads_toml "$case_dir"
  make_beads_tasks_axi_stub "$case_dir" "$id"
  make_bd_stub "$case_dir"

  out=$(run_ship_spawn "$case_dir" "$id") || fail "spawn failed: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_contains "$(bd_calls "$case_dir")" "BEADS_DIR=$(home_of "$case_dir")/.beads assign $id $id" \
    "spawn did not stamp the assignee against the configured graph path"
  pass "a beads home stamps the spawned crewmate as its bead's assignee"
}

test_markdown_spawn_makes_no_bd_call() {
  local case_dir id out
  id=beads-assign-md1
  case_dir=$(make_home assign-markdown "$id")
  add_item "$case_dir" "$id"
  make_bd_stub "$case_dir"

  out=$(run_ship_spawn "$case_dir" "$id") || fail "spawn failed: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ -z "$(bd_calls "$case_dir")" ] \
    || fail "a non-beads home invoked bd: $(bd_calls "$case_dir")"
  pass "a markdown home skips the assignee stamp quietly"
}

test_secondmate_spawn_skips_a_missing_bead_quietly() {
  local case_dir id out
  id=beads-assign-sm1
  case_dir=$(make_home assign-secondmate "$id")
  write_beads_toml "$case_dir"
  make_bd_stub "$case_dir" 1

  out=$(run_secondmate_spawn "$case_dir" "$id") || fail "spawn failed: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  case "$out" in
    *"could not be stamped"*) fail "a secondmate spawn surfaced a warning for its expected missing bead" ;;
  esac
  pass "a secondmate spawn skips its missing bead quietly"
}

test_ship_spawn_survives_a_failed_stamp() {
  local case_dir id out
  id=beads-assign-fail1
  case_dir=$(make_home assign-failure "$id")
  write_beads_toml "$case_dir"
  make_beads_tasks_axi_stub "$case_dir" "$id"
  make_bd_stub "$case_dir" 1

  out=$(run_ship_spawn "$case_dir" "$id") || fail "spawn failed: $out"
  assert_contains "$out" "spawned $id" "a failed stamp must not fail the spawn"
  assert_contains "$out" "could not be stamped" \
    "a crewmate spawn did not report its failed assignee stamp"
  pass "a failed assignee stamp is best-effort and reported"
}

test_absent_beads_binary_skips_quietly() {
  local case_dir id out
  id=beads-assign-nobd
  case_dir=$(make_home assign-no-binary "$id")
  write_beads_toml "$case_dir" 'binary = "beads-binary-not-installed"'
  make_beads_tasks_axi_stub "$case_dir" "$id"

  out=$(run_ship_spawn "$case_dir" "$id") || fail "spawn failed: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  case "$out" in
    *"could not be stamped"*) fail "an absent beads binary surfaced a warning" ;;
  esac
  pass "an absent beads binary skips the assignee stamp quietly"
}

test_beads_relaunch_never_restamps_the_assignee() {
  local case_dir id out calls
  id=beads-assign-rl1
  case_dir=$(make_home assign-relaunch "$id")
  write_beads_toml "$case_dir"
  make_beads_tasks_axi_stub "$case_dir" "$id"
  make_bd_stub "$case_dir"

  out=$(run_ship_spawn "$case_dir" "$id") || fail "fresh spawn failed: $out"
  assert_contains "$out" "spawned $id" "fresh spawn did not report success"
  calls=$(bd_calls "$case_dir")
  assert_contains "$calls" "assign $id $id" "fresh spawn did not stamp the assignee"

  # The recorded window's name part is the only fixture detail the relaunch's
  # tmux stub needs; take it from the fresh spawn's own success line.
  window_name=$(printf '%s\n' "$out" | sed -n 's/.* window=[^:]*:\([^ ]*\) .*/\1/p')
  [ -n "$window_name" ] || fail "could not read the fresh spawn's recorded window from: $out"

  out=$(run_ship_relaunch "$case_dir" "$id" "$window_name") || fail "relaunch failed: $out"
  assert_contains "$out" "spawned $id" "relaunch did not report success"
  [ "$(bd_calls "$case_dir")" = "$calls" ] \
    || fail "a relaunch re-stamped the assignee: $(bd_calls "$case_dir")"
  pass "a relaunch leaves the bead's assignee untouched"
}

test_beads_ship_spawn_stamps_the_assignee
test_markdown_spawn_makes_no_bd_call
test_secondmate_spawn_skips_a_missing_bead_quietly
test_ship_spawn_survives_a_failed_stamp
test_absent_beads_binary_skips_quietly
test_beads_relaunch_never_restamps_the_assignee
