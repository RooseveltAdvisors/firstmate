#!/usr/bin/env bash
# reclaim-demo.sh <firstmate-tree> <label>
#
# Drives the real fm-control.sh / fm-spawn.sh CLI against a hermetic fixture
# that reproduces the reported deadlock: a herdr-backed ship task, parked on a
# no-mistakes approval, whose recorded pane was destroyed in herdr churn while
# its session server kept running. Prints a plain operator transcript.
set -u
TREE=$1
LABEL=$2
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-reclaim-demo.XXXXXX")
ID=zeelx
SES=fmlab

cleanup() { rm -rf "$ROOT" "/tmp/fm-$ID" "/tmp/fm-alive1" "/tmp/fm-tmux1"; }
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
rule() { printf '%s\n' "------------------------------------------------------------"; }

# --- fixture ---------------------------------------------------------------
mkdir -p "$ROOT/home/state" "$ROOT/home/data/$ID" "$ROOT/fake" "$ROOT/fakebin" "$ROOT/user-home"

cat > "$ROOT/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
# Canned herdr CLI. Never a real herdr session.
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/herdr-log"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n'; exit 0
fi
[ "${1:-}" = server ] && exit 0
case "${1:-} ${2:-}" in
  'pane get')
    if [ "${3:-}" = "$(cat "$D/herdr-pane")" ]; then
      printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' "${3:-}" "$(cat "$D/cwd")"
    else
      printf '{"error":{"code":"pane_not_found"}}\n'
    fi
    exit 0 ;;
  'agent get')
    if [ -f "$D/herdr-agent-live" ]; then
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else
      printf '{"error":{"code":"agent_not_found"}}\n'
    fi
    exit 0 ;;
  'pane process-info')
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"claude","argv":["claude"],"cmdline":"claude"}]}}}\n' "$(cat "$D/herdr-pane")"
    exit 0 ;;
  'pane send-text')
    case "$*" in *'encode launch-brief'*) : > "$D/herdr-agent-live" ;; esac
    exit 0 ;;
  'workspace list') printf '{"result":{"workspaces":[]}}\n'; exit 0 ;;
  'workspace create') printf '{"result":{"workspace":{"workspace_id":"wsnew"},"tab":{"tab_id":"seedtab"}}}\n'; exit 0 ;;
  'tab list') printf '{"result":{"tabs":[]}}\n'; exit 0 ;;
  'tab create')
    printf '%s\n' "$*" >> "$D/herdr-created-tabs"
    printf '{"result":{"tab":{"tab_id":"tabnew"},"root_pane":{"pane_id":"%%9"}}}\n'
    printf '%s' '%9' > "$D/herdr-pane"
    exit 0 ;;
esac
exit 0
SH
chmod +x "$ROOT/fakebin/herdr"

# Project + worktree holding real, unlanded work.
PROJ=$ROOT/proj WT=$ROOT/wt
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid
mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md && git -C "$PROJ" commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "file://$PROJ.origin.git"
git -C "$PROJ" worktree add --quiet -b "task-$ID" "$WT"
printf 'the feature this task shipped\n' > "$WT/feature.txt"
git -C "$WT" add feature.txt && git -C "$WT" commit -qm "work in progress"
HEAD_BEFORE=$(git -C "$WT" rev-parse HEAD)
printf 'not committed anywhere\n' > "$WT/scratch.txt"

cat > "$ROOT/home/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Ship the endpoint reclaim fix.

## Firstmate spec
Park on the no-mistakes approval gate and wait for an answer.
EOF
{
  echo "window=$SES:%7"
  echo "endpoint_task_id=$ID"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "tasktmp=/tmp/fm-$ID"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SES"
  echo "herdr_workspace_id=ws1"
  echo "herdr_tab_id=tab1"
  echo "herdr_pane_id=%7"
  echo "pr=https://example.invalid/pr/4031"
} > "$ROOT/home/state/$ID.meta"
printf 'working: parked on a no-mistakes ask-user gate, waiting on the captain\n' \
  > "$ROOT/home/state/$ID.status"
printf '%s' "$WT" > "$ROOT/fake/cwd"
# The recorded pane %7 was destroyed in herdr churn; the session server is up.
printf '%s' '%none' > "$ROOT/fake/herdr-pane"
: > "$ROOT/fake/herdr-log"

fm() {  # <args...>  -> runs the real control-plane CLI
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$ROOT/fakebin:$PATH" FM_HOME="$ROOT/home" FM_FAKE_DIR="$ROOT/fake" \
    HOME="$ROOT/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_GATE_REFUSE_BYPASS=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$@" 2>&1
}

meta() { grep "^$1=" "$ROOT/home/state/$ID.meta" | tail -1; }

say "================================================================"
say "  firstmate endpoint reclaim - operator transcript ($LABEL)"
say "================================================================"
say "task            : $ID (ship, no-mistakes, parked on an approval gate)"
say "recorded endpoint: $(meta window | cut -d= -f2-)   [herdr session $SES]"
say "state of the world: that herdr pane was destroyed in churn; the session"
say "                    server is still running, so the record points at an"
say "                    address that no longer exists."
say "worktree        : HEAD $HEAD_BEFORE on branch $(git -C "$WT" rev-parse --abbrev-ref HEAD), 1 uncommitted file"
rule

say '$ bin/fm-control.sh '"$ID"' exit'
out=$(fm "$TREE/bin/fm-control.sh" "$ID" exit); rc=$?
printf '%s\n' "$out"
say "[exit status $rc]"
rule

say '$ bin/fm-control.sh '"$ID"' relaunch --note "the pane was destroyed in herdr churn; pick the work back up"'
out=$(fm "$TREE/bin/fm-control.sh" "$ID" relaunch --note "the pane was destroyed in herdr churn; pick the work back up"); rc=$?
printf '%s\n' "$out"
say "[exit status $rc]"
rule

say "AFTER BOTH COMMANDS - what the operator can inspect:"
say "  recorded endpoint : $(meta window | cut -d= -f2-)"
say "  herdr session     : $(meta herdr_session | cut -d= -f2-)"
say "  herdr pane        : $(meta herdr_pane_id | cut -d= -f2-)"
say "  worktree          : $(meta worktree | cut -d= -f2-)"
say "  worktree HEAD     : $(git -C "$WT" rev-parse HEAD) ($([ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD_BEFORE" ] && echo unchanged || echo CHANGED))"
say "  worktree branch   : $(git -C "$WT" rev-parse --abbrev-ref HEAD)"
say "  uncommitted file  : $([ -f "$WT/scratch.txt" ] && cat "$WT/scratch.txt" || echo MISSING)"
say "  herdr workspace   : $(meta herdr_workspace_id | cut -d= -f2-)  (was ws1 - the container follows the reclaiming seat, as documented)"
say "  pr row            : $(meta pr | cut -d= -f2-)"
say "  status log        : $(cat "$ROOT/home/state/$ID.status")"
say "  brief progress note: $(grep -c '^## Progress note' "$ROOT/home/data/$ID/brief.md") block(s) appended; last line: $(tail -1 "$ROOT/home/data/$ID/brief.md")"
say "  herdr calls made  : $(sort -u "$ROOT/fake/herdr-log" | tr '\n' '|' | sed 's/|/ ; /g')"
rule
