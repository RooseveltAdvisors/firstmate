#!/usr/bin/env bash
# Manual end-to-end evidence capture: run the real bin/fm-spawn.sh against a
# fixture beads home and record the spawn transcript plus the bd call log.
# Reuses the repo's own test fixture builders so the world matches CI.
set -u
ROOT=/home/jon/.no-mistakes/worktrees/46339c0817e0/01M214CWKEJ01E9P1ABQQ2BDGA
EV=/home/jon/.no-mistakes/evidence/01M214CWKEJ01E9P1ABQQ2BDGA

# Isolate ambient env exactly like the suite does.
unset TASKS_AXI_BACKEND HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH HERDR_PANE_ID || :
unset FM_TASK_ID
export FM_GATE_REFUSE_BYPASS=1
umask 022

# --- fixture (same shape as tests/fm-spawn-beads-assign.test.sh make_home) ---
id=demo-assign-1
case_dir=$(mktemp -d /tmp/fm-assign-evidence.XXXXXX)
home="$case_dir/home"
fakebin="$case_dir/fakebin"
mkdir -p "$fakebin" "$home/state" "$home/config" "$home/data" "$home/projects"
touch "$home/state/.last-watcher-beat"
printf '%s\n' claude > "$home/config/crew-harness"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
mkdir -p "$home/data/$id"
cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Demo the spawn-time beads assignee stamp for $id.

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
for t in treehouse gh gh-axi no-mistakes; do printf '#!/bin/sh\nexit 0\n' > "$fakebin/$t"; chmod +x "$fakebin/$t"; done

git -c user.email=e@x -c user.name=e init -q "$case_dir/project"
git -C "$case_dir/project" commit -q --allow-empty -m init
git init -q --bare "$case_dir/project.origin.git"
git -C "$case_dir/project" remote add origin "$case_dir/project.origin.git"
git -C "$case_dir/project" push -q origin HEAD
FETCH_HEAD= git -C "$case_dir/project" fetch -q origin
git -C "$case_dir/project" worktree add --quiet -b pooled "$case_dir/wt"

# tasks-axi stub: beads backend with the fixture row
cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/tasks-axi-calls"
case "\${1:-}" in
  --version) printf '%s\n' '0.2.5' ;;
  update) [ "\${2:-}" = --help ] || exit 1; printf '%s\n' '--archive-body' ;;
  mv) [ "\${2:-}" = --help ] || exit 1; printf '%s\n' 'usage: tasks-axi mv [<id>...]' ;;
  show)
    [ "\${2:-}" = "$id" ] || exit 1
    printf '%s\n' 'task:'
    printf '  id: %s\n' "$id"
    printf '%s\n' '  state: in_flight' '  held: no' '  blocked: no'
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$fakebin/tasks-axi"

# bd stub: records every invocation
cat > "$fakebin/bd" <<SH
#!/usr/bin/env bash
printf '%s\n' "BEADS_DIR=\${BEADS_DIR:-unset} \$*" >> "$case_dir/bd-calls"
exit 0
SH
chmod +x "$fakebin/bd"

printf '%s\n' 'backend = "beads"' '[beads]' 'path = ".beads"' 'prefix = "fm"' > "$home/.tasks.toml"

# --- run the real spawn ------------------------------------------------------
{
  echo '$ fm-spawn.sh '"$id"' <project> --mode no-mistakes --yolo off'
  echo '--- spawn transcript (stderr merged) ---'
  mkdir -p "$case_dir/user-home"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$case_dir/wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$case_dir/project" --mode no-mistakes --yolo off
  rc=$?
  echo "--- exit code: $rc ---"
  echo '--- recorded bd invocations (bd-calls log) ---'
  cat "$case_dir/bd-calls"
} > "$EV/spawn-assign-transcript.txt" 2>&1

echo "evidence written: $EV/spawn-assign-transcript.txt"
rm -rf "$case_dir"
