#!/usr/bin/env bash
# Evidence driver: drives the real firstmate CLIs end to end against scratch
# fixtures and captures the end-user-visible transcripts. Lives in the
# evidence directory; the only worktree files it touches are reads/sources.
set -u

ROOT=/home/jon/.no-mistakes/worktrees/2f32188048b1/01M28RB8449BAAVRW5YC0274EX
EVID=/home/jon/.no-mistakes/evidence/01M28RB8449BAAVRW5YC0274EX
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-evidence-demo)
export PATH="$ROOT/bin:$PATH"

section() { printf '\n================ %s ================\n' "$1"; }

# ---------------------------------------------------------------------------
section "1. Stale-claim sweep: dry run, apply, graph read-back"
# ---------------------------------------------------------------------------
SWEEP="$ROOT/bin/fm-stale-sweep.sh"
case1="$TMP_ROOT/sweep"
home="$case1/home"
graph="$case1/fm"
mkdir -p "$home/data" "$home/state" "$graph"
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

AXI_CLAIM_MARKER='<!-- tasks-axi:beads/v1:eyJraW5kIjoic2hpcCJ9 -->'
# Stand-in tasks-axi speaking beads, for the mutation home (the npm-published
# tasks-axi ships markdown only). Same shim shape the suite uses.
mkdir -p "$case1/fakebin"
cat > "$case1/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
verb=${1:-}
id=${2:-}
shift 2 2>/dev/null || true
graph=$(awk '/^\[beads\]/{s=1;next} /^\[/{s=0} s && /^[[:space:]]*path[[:space:]]*=/{sub(/^[^"]*"/,"");sub(/".*$/,"");print;exit}' .tasks.toml)
[ -n "$graph" ] || { echo 'error: not a beads-backed home' >&2; exit 1; }
export BEADS_DIR=$graph
row=$(bd show "$id" --json 2>/dev/null) || exit 1
[ -n "$row" ] || exit 1
desc=$(printf '%s' "$row" | jq -r '.[0].description // ""')
marker=$(printf '%s\n' "$desc" | sed -n '1{/^<!-- tasks-axi:beads\/v1:.*-->$/p}')
body=$(printf '%s\n' "$desc" | sed '1{/^<!-- tasks-axi:beads\/v1:.*-->$/d}')
case "$verb" in
  show)
    state=$(printf '%s' "$row" | jq -r '.[0].status | if . == "in_progress" then "in_flight" elif . == "open" then "queued" elif . == "closed" then "done" else . end')
    held=no; blocked=no
    printf 'task:\n  id: %s\n  state: %s\n  blocked: %s\n  held: %s\n  body: %s\n' \
      "$id" "$state" "$blocked" "$held" "$(printf '%s' "$body" | jq -Rs .)"
    ;;
  update)
    new=
    while [ $# -gt 0 ]; do [ "$1" = --body ] && { new=${2:-}; break; }; shift; done
    [ -z "$marker" ] || new=$(printf '%s\n%s' "$marker" "$new")
    bd update "$id" --description "$new" >/dev/null 2>&1
    ;;
  reopen) bd update "$id" --status open >/dev/null 2>&1 ;;
  *) echo "error: unsupported verb $verb" >&2; exit 1 ;;
esac
exit 0
SH
cat > "$case1/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *%dead*) exit 1 ;; esac; done
    printf '%%1\n'; exit 0 ;;
esac
exit 0
SH
cat > "$case1/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$case1/fakebin/"*

mkdir -p "$case1/wt-dead" "$case1/wt-live"
git -C "$case1/wt-dead" init -q -b fm/dead
git -C "$case1/wt-live" init -q -b fm/live

env BEADS_DIR="$graph/.beads" bd create "ship the widget" --id fm-dead-row \
  --description "$AXI_CLAIM_MARKER" >/dev/null
env BEADS_DIR="$graph/.beads" bd update fm-dead-row --claim >/dev/null
env BEADS_DIR="$graph/.beads" bd create "ship the gadget" --id fm-live-row \
  --description "$AXI_CLAIM_MARKER" >/dev/null
env BEADS_DIR="$graph/.beads" bd update fm-live-row --claim >/dev/null

fm_write_meta "$home/state/fm-dead-row.meta" \
  "window=firstmate:%dead" "worktree=$case1/wt-dead" "kind=ship" "harness=claude"
fm_write_meta "$home/state/fm-live-row.meta" \
  "window=firstmate:%live" "worktree=$case1/wt-live" "kind=ship" "harness=claude"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" fm-live-row)
"$ROOT/bin/fm-busy-event.sh" apply "$home/state" fm-live-row busy --gen "$gen" \
  --source claude-hook --event user-prompt-submit

# The sweep's default threshold is 24h; pin its clock 50h past the fixture's
# creation (the same way the suite does) so the fresh rows are past cutoff.
FM_STALE_SWEEP_NOW=$(( $(date +%s) + 50 * 3600 ))
run_sweep() {
  PATH="$case1/fakebin:$PATH" FM_STALE_SWEEP_NOW=$FM_STALE_SWEEP_NOW \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$SWEEP" "$@" 2>&1
}

{
  echo '# (sweep clock pinned 50h past fixture creation; the default threshold is 24h)'
  echo
  echo '$ fm-stale-sweep.sh            # dry run over the shared Beads graph'
  run_sweep
  echo
  echo '$ fm-stale-sweep.sh --apply'
  run_sweep --apply
  echo
  echo '# graph read-back after --apply (the dead row reopened, live row untouched):'
  for id in fm-dead-row fm-live-row; do
    printf '%s status=%s description:\n%s\n' "$id" \
      "$(env BEADS_DIR="$graph/.beads" bd show "$id" --json | jq -r '.[0].status')" \
      "$(env BEADS_DIR="$graph/.beads" bd show "$id" --json | jq -r '.[0].description')"
  done
} > "$EVID/demo-stale-sweep-transcript.txt" 2>&1
cat "$EVID/demo-stale-sweep-transcript.txt"

# ---------------------------------------------------------------------------
section "2. Capacity hold: full pool spawn refusal -> recorded hold -> teardown release"
# ---------------------------------------------------------------------------
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"

case2="$TMP_ROOT/cap"
chome="$case2/home"
proj="$case2/project"
cpool="$case2/pool"
mkdir -p "$chome/data" "$chome/projects" "$chome/state" "$chome/config" "$cpool"
touch "$chome/state/.last-watcher-beat"
printf 'codex\n' > "$chome/config/crew-harness"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$chome/data/backlog.md"
tasks-axi add cap-x1 "capacity demo task" --kind ship --file "$chome/data/backlog.md" >/dev/null
mkdir -p "$chome/data/cap-x1"
cat > "$chome/data/cap-x1/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise the pool-full capacity hold.
## Firstmate spec
Detect the treehouse refusal and hold the item.
EOF
fm_git_worktree "$proj" "$case2/wt" "wt-cap" >/dev/null 2>&1

mkdir -p "$case2/fakebin"
cat > "$case2/fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"\#{pane_current_path}"*) printf '%s\n' "$proj"; exit 0 ;;
esac
case "\${1:-}" in
  capture-pane) cat "$case2/refusal.txt" 2>/dev/null; exit 0 ;;
  display-message)
    case "\$*" in
      *'#{pane_id}'*)
        if [ -s "$case2/tmux-kill.log" ]; then exit 1; fi
        printf '%%1\n'; exit 0 ;;
    esac
    printf 'firstmate\n'; exit 0 ;;
esac
case "\${1:-}" in
  kill-window) printf '%s\n' "\$*" >> "$case2/tmux-kill.log"; exit 0 ;;
esac
exit 0
SH
cat > "$case2/fakebin/treehouse" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "status --json")
    printf '[{"name":"7","path":"$cpool/7/project","status":"in-use","flavor":"git","lease_id":"","lease_holder":"","leased_at":null,"processes":[]}]'
    exit 0 ;;
esac
exit 0
SH
chmod +x "$case2/fakebin/"*
cat > "$case2/refusal.txt" <<'EOF'
$ treehouse get
all 3 worktrees are in use or dirty
(max_trees = 4). Run 'treehouse
status' to see details, or increase
max_trees in treehouse.toml
EOF

spawn_home="$case2/user-home"; mkdir -p "$spawn_home"
{
  echo '$ fm-spawn.sh cap-x1 <project> --mode no-mistakes --yolo off   # pool is full (3/4)'
  FM_ROOT_OVERRIDE='' FM_HOME="$chome" HOME="$spawn_home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$chome/state" FM_DATA_OVERRIDE="$chome/data" \
    FM_PROJECTS_OVERRIDE="$chome/projects" FM_CONFIG_OVERRIDE="$chome/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$case2/fakebin:$PATH" \
    "$SPAWN" cap-x1 "$proj" --mode no-mistakes --yolo off 2>&1
  echo "(spawn exit code: $?)"
  echo
  echo '# backlog read-back after the hold:'
  tasks-axi show cap-x1 --file "$chome/data/backlog.md" 2>/dev/null
} > "$EVID/demo-capacity-hold-spawn-transcript.txt" 2>&1
cat "$EVID/demo-capacity-hold-spawn-transcript.txt"

# Teardown release: land a task in a worktree of the same pool and tear it down.
tc="$TMP_ROOT/cap-release"
tfake="$tc/fakebin"; tpool="$tc/pool"
mkdir -p "$tc/state" "$tc/config" "$tc/data" "$tfake" "$tpool"
cat > "$tfake/treehouse" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "status --json")
    printf '[{"name":"7","path":"$tpool/7/wt","status":"in-use","flavor":"git","lease_id":"","lease_holder":"","leased_at":null,"processes":[]}]'
    exit 0 ;;
esac
exit 0
SH
cat > "$tfake/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$tfake/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
cat > "$tfake/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
cat > "$tfake/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  axi) shift; case "${1:-}" in status) shift; printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;; esac ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
chmod +x "$tfake/"*
git init -q --bare "$tc/origin.git"
git -C "$tc/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$tc/origin.git" "$tc/_seed"
git -C "$tc/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "origin baseline"
git -C "$tc/_seed" push -q origin main
rm -rf "$tc/_seed"
git clone -q "$tc/origin.git" "$tc/project"
git -C "$tc/project" worktree add -q -b fm/task-x1 "$tpool/7/wt" main
git -C "$tpool/7/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "wt work"
git init -q --bare "$tc/fork.git"
git -C "$tc/project" remote add fork "$tc/fork.git"
git -C "$tpool/7/wt" push -q fork fm/task-x1
git -C "$tc/project" fetch -q fork
touch "$tc/state/.last-watcher-beat"
fm_write_meta "$tc/state/task-x1.meta" \
  "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
  "worktree=$tpool/7/wt" "project=$tc/project" "kind=ship" \
  "mode=local-only" "spawn_gen=capacity-demo-task-x1"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$tc/data/backlog.md"
tasks-axi add task-x1 "teardown demo task" --kind ship --file "$tc/data/backlog.md" >/dev/null
tasks-axi start task-x1 --file "$tc/data/backlog.md" >/dev/null
tasks-axi add task-a "oldest held" --kind ship --file "$tc/data/backlog.md" >/dev/null
tasks-axi add task-b "newer held" --kind ship --file "$tc/data/backlog.md" >/dev/null
tasks-axi hold task-a --reason "pool $tpool full 3/4" --kind load --file "$tc/data/backlog.md" >/dev/null
tasks-axi hold task-b --reason "pool $tpool full 3/4" --kind load --file "$tc/data/backlog.md" >/dev/null
{
  echo '# before teardown: task-a held=yes (oldest), task-b held=yes (newer), same pool'
  echo '$ fm-teardown.sh task-x1   # a landed worktree is returned to the pool'
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$tc/state" \
    FM_DATA_OVERRIDE="$tc/data" FM_CONFIG_OVERRIDE="$tc/config" \
    PATH="$tfake:$PATH" "$TEARDOWN" task-x1 2>&1
  echo "(teardown exit code: $?)"
  echo
  echo '# backlog read-back after the release:'
  for id in task-a task-b; do
    printf '%s: %s\n' "$id" "$(tasks-axi show "$id" --file "$tc/data/backlog.md" 2>/dev/null | grep -E 'state:|held:' | tr -s ' ' | tr '\n' ';')"
  done
} > "$EVID/demo-capacity-release-transcript.txt" 2>&1
cat "$EVID/demo-capacity-release-transcript.txt"

# ---------------------------------------------------------------------------
section "3. No-mistakes mirror drift: session start reports the drifted gate remote"
# ---------------------------------------------------------------------------
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID 2>/dev/null || true

case3="$TMP_ROOT/mirror"
mhome="$case3/home"
root_a="$case3/root-a"
root_b="$case3/root-b"
mkdir -p "$mhome/config" "$mhome/data" "$mhome/projects"
printf '%s\n' manual > "$mhome/config/backlog-backend"
# minimal fake toolchain so bootstrap's requirement probes pass
mkdir -p "$case3/fakebin"
fm_fake_exit0 "$case3/fakebin" tmux node chrome-devtools-axi
fm_fake_version_tool "$case3/fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
cat > "$case3/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '%s\n' 0.1.29; exit 0; }
exit 0
SH
cat > "$case3/fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] && exit 0
exit 0
SH
cat > "$case3/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = get ] && [ "${2:-}" = --help ] && { printf '%s\n' 'Usage: treehouse get [--lease]'; exit 0; }
exit 0
SH
cat > "$case3/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '%s\n' 'no-mistakes version v1.46.0 (fake)'; exit 0; }
exit 0
SH
cat > "$case3/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '%s\n' 0.2.4; exit 0; }
[ "${1:-} ${2:-}" = "update --help" ] && { printf '%s\n' 'usage: tasks-axi update <id> [--archive-body]'; exit 0; }
[ "${1:-} ${2:-}" = "mv --help" ] && { printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'; exit 0; }
exit 0
SH
cat > "$case3/fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '%s\n' 0.1.29; exit 0; }
exit 0
SH
chmod +x "$case3/fakebin/"*
mkdir -p "$case3/non-git-root"

cat > "$mhome/data/projects.md" <<'REG'
- macro [no-mistakes] - drift fixture (added 2026-09-04)
- well [no-mistakes] - healthy fixture (added 2026-09-04)
REG
git init -q -b main "$mhome/projects/macro"
git -C "$mhome/projects/macro" remote add no-mistakes "$root_b/repos/macro.git"   # WRONG root -> drift
git init -q -b main "$mhome/projects/well"
git -C "$mhome/projects/well" remote add no-mistakes "$root_a/repos/well.git"     # right root -> silent

{
  echo '# session start with one clone whose no-mistakes gate remote points at'
  echo '# another data root (root-b) than the one the CLI resolves (root-a):'
  echo
  echo '$ fm-bootstrap.sh'
  PATH="$case3/fakebin:$PATH" NM_HOME="$root_a" FM_HOME="$mhome" \
    FM_ROOT_OVERRIDE="$case3/non-git-root" FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
  echo "(bootstrap exit code: $?)"
} > "$EVID/demo-mirror-drift-transcript.txt" 2>&1
cat "$EVID/demo-mirror-drift-transcript.txt"

section "DONE - transcripts written to $EVID"
