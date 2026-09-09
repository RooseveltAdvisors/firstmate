#!/usr/bin/env bash
# Manual end-to-end demonstration: a Beads-configured firstmate home whose
# spawn and teardown lifecycle transitions run against a REAL tasks-axi 0.2.5
# + REAL bd (beads) CLI — no stubbed tasks-axi.
set -u
ROOT=/home/jon/.no-mistakes/worktrees/2f32188048b1/01M23X6633SZ0MFFTZXTKQN6CY
case_dir=/tmp/fm-beads-e2e/case
home=$case_dir/home
id=home-e2e-1
rm -rf "$case_dir"
mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects" "$case_dir/user-home"
touch "$home/state/.last-watcher-beat"
printf '%s\n' claude > "$home/config/crew-harness"

fakebin=$case_dir/fakebin
mkdir -p "$fakebin"
cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
chmod +x "$fakebin/tmux"
for tool in treehouse gh gh-axi no-mistakes; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$tool"
  chmod +x "$fakebin/$tool"
done

mkdir -p "$case_dir/user-home/.local/bin"
ln -s "$(command -v bd)" "$case_dir/user-home/.local/bin/bd"

# Real project clone with origin + pooled worktree (same fixture the suite uses).
git init -q "$case_dir/project"
git -C "$case_dir/project" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q --allow-empty -m init
git clone -q --bare "$case_dir/project" "$case_dir/project.origin.git"
git -C "$case_dir/project" worktree add -q -b pooled "$case_dir/wt"

# A REAL beads database at the addressing root, and a REAL tasks-axi beads
# adapter configured through the home's .tasks.toml.
git -C "$home" init -q
(cd "$home" && bd init >/dev/null 2>&1)
cat > "$home/.tasks.toml" <<'EOF'
backend = "beads"

[beads]
path = ".beads"
prefix = "home"
EOF

mkdir -p "$home/data/$id"
cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Demonstrate bead lifecycle transitions end to end.

## Firstmate spec
Dispatch this ship task and complete it.

# Definition of done
Delivery contract: mode=no-mistakes
EOF

# The beads task the ship spawn will dispatch.
(cd "$home" && tasks-axi add "$id" "demonstrate bead lifecycle transitions end to end" --kind ship) >/dev/null

echo "=== BEFORE: bead state (real tasks-axi show over the real beads db) ==="
(cd "$home" && tasks-axi show "$id")

echo
echo "=== RUN: bin/fm-spawn.sh $id (FM_HOME=$home, backend=beads) ==="
env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" HOME="$case_dir/user-home" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$case_dir/wt" TMUX="fake,1,0" \
  CLAUDE_CONFIG_DIR='' PATH="$fakebin:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$id" "$case_dir/project" --mode no-mistakes --yolo off
spawn_rc=$?
echo "spawn exit: $spawn_rc"

echo
echo "=== AFTER SPAWN ==="
echo "--- bead state (tasks-axi show, no --file):"
(cd "$home" && tasks-axi show "$id")
echo "--- published task record:"
cat "$home/state/$id.meta"

# Land the work so teardown accepts it: record the PR, keep the worktree clean.
printf 'pr=https://github.com/example/firstmate/pull/4202\n' >> "$home/state/$id.meta"

echo
echo "=== RUN: bin/fm-teardown.sh $id ==="
env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
  PATH="$fakebin:$PATH" \
  "$ROOT/bin/fm-teardown.sh" "$id"
teardown_rc=$?
echo "teardown exit: $teardown_rc"

echo
echo "=== AFTER TEARDOWN ==="
echo "--- bead state (tasks-axi show):"
(cd "$home" && tasks-axi show "$id")
echo "--- task record after teardown:"
ls "$home/state/$id.meta" 2>&1 || true
echo "--- markdown backlog file (must never have existed for this beads home):"
ls "$home/data/backlog.md" 2>&1 || true
