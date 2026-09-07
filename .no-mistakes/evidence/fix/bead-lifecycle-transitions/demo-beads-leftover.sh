#!/usr/bin/env bash
# End-to-end demo: a Beads home with a leftover markdown symlink at
# <data>/backlog.md must spawn, dispatch (beads adapter, no --file), and tear
# down cleanly. Mirrors the user-facing scenario from review round 2, finding 1.
set -u
ROOT=/home/jon/.no-mistakes/worktrees/2f32188048b1/01M1XQNSXBBZBWKKSRN6CY2PKV
DEMO=$(mktemp -d /tmp/fm-beads-demo.XXXXXX)
case_dir=$DEMO/case
home=$case_dir/home
id=demo-beads-b1
mkdir -p "$case_dir/fakebin" "$home/config" "$home/data" "$home/archive" "$home/state" "$home/projects" "$case_dir/wt"
printf '%s\n' claude > "$home/config/crew-harness"
printf '%s\n' 'backend = "beads"' '[beads]' 'path = ".beads"' 'prefix = "demo"' > "$home/.tasks.toml"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/archive/backlog.md"
ln -s ../archive/backlog.md "$home/data/backlog.md"   # the leftover symlink
mkdir -p "$home/data/$id"
cat > "$home/data/$id/brief.md" <<BRIEF
# Task
## Captain's intent
Exercise backlog dispatch for $id.

## Firstmate spec
Verify the atomic backlog transition.

# Definition of done
Delivery contract: mode=no-mistakes
BRIEF
fm_git_init_commit() {
  git -C "$1" init -q
  git -C "$1" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q --allow-empty -m seed
}
mkdir -p "$case_dir/project"
fm_git_init_commit "$case_dir/project"
git -C "$case_dir/project" remote add origin "$case_dir/project"
git -C "$case_dir/project" worktree add --quiet -b pooled "$case_dir/wt"
# Stub the tools spawn/teardown shell out to.
cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
chmod +x "$case_dir/fakebin/tmux"
for tool in treehouse gh gh-axi no-mistakes; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$case_dir/fakebin/$tool"
  chmod +x "$case_dir/fakebin/$tool"
done
# Beads adapter stub: records every invocation; behaves like a real beads-backed
# tasks-axi for the verbs the lifecycle drives.
cat > "$case_dir/fakebin/tasks-axi" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/tasks-axi-calls"
case "\${1:-}" in
  --version) printf '0.2.5\\n' ;;
  update) [ "\${2:-}" = --help ] || exit 1; printf '%s\\n' '--archive-body' ;;
  mv) [ "\${2:-}" = --help ] || exit 1; printf '%s\\n' 'usage: tasks-axi mv [<id>...]' ;;
  show)
    if [ "\${3:-}" = --file ]; then
      printf '%s\\n' 'error: beads show failed' >&2
      exit 1
    fi
    printf 'task:\\n  state: queued\\n  held: no\\n  blocked: no\\n'
    ;;
  start) printf '%s\\n' "started \$2" ;;
  done) exit 0 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$case_dir/fakebin/tasks-axi"
export FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1
export FM_FAKE_PANE_PATH="$case_dir/wt" TMUX="fake,1,0" CLAUDE_CONFIG_DIR=''
unset NO_MISTAKES_GATE
export PATH="$case_dir/fakebin:$PATH"

echo '=== Scenario: Beads home whose data/backlog.md is a leftover symlink to archive/backlog.md ==='
echo
echo '--- fm-spawn.sh (dispatch) ---'
if out=$("$ROOT/bin/fm-spawn.sh" "$id" "$case_dir/project" --mode no-mistakes --yolo off 2>&1); then
  echo "spawn exit: 0"
  echo "$out" | tail -3
else
  echo "spawn exit: $? (FAILED)"
  echo "$out" | tail -3
  exit 1
fi
echo
echo "state record published: $(test -f "$home/state/$id.meta" && echo yes || echo NO)"
echo "beads adapter invocations (note: no --file argument anywhere):"
cat "$case_dir/tasks-axi-calls"
echo
echo '--- fm-teardown.sh (completion, against a recorded worktree that no longer exists) ---'
printf 'pr=%s\n' 'https://github.com/example/firstmate/pull/42' >> "$home/state/$id.meta"
rm -rf "$case_dir/wt"
if out=$("$ROOT/bin/fm-teardown.sh" "$id" 2>&1); then
  echo "teardown exit: 0"
  echo "$out" | tail -2
else
  rc=$?
  echo "teardown exit: $rc"
  echo "$out" | tail -2
  case "$out" in
    *authorized*|*resolves*) echo "REGRESSION: teardown still refuses the beads home"; exit 1 ;;
  esac
fi
echo
echo "state record after teardown: $(test -f "$home/state/$id.meta" && echo present || echo removed)"
echo "beads adapter invocations after teardown:"
cat "$case_dir/tasks-axi-calls"
# kept for inspection: rm -rf "$DEMO"
