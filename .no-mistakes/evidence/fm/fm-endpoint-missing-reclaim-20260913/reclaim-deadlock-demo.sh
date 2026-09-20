#!/usr/bin/env bash
# reclaim-deadlock-demo.sh <code-root> <label>
#
# Operator-level reproduction of the endpoint re-binding deadlock named in this
# change's intent, run against an arbitrary firstmate code root so the SAME
# scenario can be replayed on the base commit and on the fix.
#
# Scenario (the intent's trigger, exactly): a ship task recorded on the herdr
# backend at session `fmlab`, pane `%7`. The pane was destroyed in herdr churn.
# That session's server is still RUNNING, so this is not a merely unreachable
# endpoint - the pane genuinely does not exist and herdr answers
# `pane_not_found`. The task is parked on a no-mistakes approval, has one
# commit on its branch and one uncommitted file.
#
# Each of the three commands an operator would reach for is run against its own
# FRESH copy of that stranded task, so no attempt is coloured by a previous one:
#   bin/fm-control.sh <id> exit
#   bin/fm-spawn.sh   <id> --relaunch --harness claude
#   bin/fm-control.sh <id> relaunch --note "..."
#
# Everything runs against a throwaway FM_HOME, a throwaway user HOME and a
# canned `herdr` CLI. No real herdr session, no real agent, no network.
# FM_GATE_REFUSE_BYPASS=1 is the sanctioned test-harness escape hatch documented
# in bin/fm-gate-refuse-lib.sh, needed because this runs from a gate worktree.
set -u

ROOT=${1:?usage: reclaim-deadlock-demo.sh <code-root> <label>}
LABEL=${2:?usage: reclaim-deadlock-demo.sh <code-root> <label>}
SES=fmlab

TOP=$(mktemp -d /tmp/fm-reclaim-demo.XXXXXX)
CASE_IDS=()
cleanup() {
  local id
  rm -rf "$TOP"
  for id in "${CASE_IDS[@]:-}"; do [ -n "$id" ] && rm -rf "/tmp/fm-$id"; done
}
trap cleanup EXIT

# --- canned herdr CLI: server up, recorded pane destroyed -------------------
herdr_stub() {  # <fakebin>
  cat > "$1/herdr" <<'SH'
#!/usr/bin/env bash
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
    payload=${4:-}
    case "$payload" in ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;; esac
    case "$payload" in *'encode launch-brief'*) : > "$D/herdr-agent-live" ;; esac
    exit 0 ;;
  'workspace list') printf '{"result":{"workspaces":[]}}\n'; exit 0 ;;
  'workspace create') printf '{"result":{"workspace":{"workspace_id":"wsnew"},"tab":{"tab_id":"seedtab"}}}\n'; exit 0 ;;
  'tab list') printf '{"result":{"tabs":[]}}\n'; exit 0 ;;
  'tab create')
    printf '{"result":{"tab":{"tab_id":"tabnew"},"root_pane":{"pane_id":"%%9"}}}\n'
    printf '%s' '%9' > "$D/herdr-pane"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/herdr"
}

# new_stranded_case <id> -> builds $TOP/<id> and echoes nothing; sets DIR.
DIR=
HEAD_BEFORE=
new_stranded_case() {  # <id>
  local id=$1
  DIR="$TOP/$id"
  CASE_IDS+=("$id")
  mkdir -p "$DIR/home/state" "$DIR/home/data/$id" "$DIR/fake" "$DIR/fakebin" "$DIR/user-home"
  git -C "$DIR" init -q -b main proj
  git -C "$DIR/proj" -c user.name=demo -c user.email=demo@example.invalid commit -q --allow-empty -m initial
  git clone --quiet --bare "$DIR/proj" "$DIR/proj.origin.git"
  git -C "$DIR/proj" remote add origin "file://$DIR/proj.origin.git"
  git -C "$DIR/proj" worktree add --quiet -b "task-$id" "$DIR/wt"
  printf 'the work this task already landed on its branch\n' > "$DIR/wt/landed.txt"
  git -C "$DIR/wt" add landed.txt
  git -C "$DIR/wt" -c user.name=demo -c user.email=demo@example.invalid commit -qm "work in progress"
  HEAD_BEFORE=$(git -C "$DIR/wt" rev-parse HEAD)
  printf 'uncommitted change the agent never got to save\n' > "$DIR/wt/dirty.txt"
  cat > "$DIR/home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Reclaim a task whose terminal was destroyed.

## Firstmate spec
Keep the task whole while its endpoint is re-created.
EOF
  {
    echo "window=$SES:%7"
    echo "endpoint_task_id=$id"
    echo "worktree=$DIR/wt"
    echo "project=$DIR/proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
    echo "backend=herdr"
    echo "herdr_session=$SES"
    echo "herdr_workspace_id=ws1"
    echo "herdr_tab_id=tab1"
    echo "herdr_pane_id=%7"
  } > "$DIR/home/state/$id.meta"
  printf 'working: parked on a no-mistakes approval nobody can answer\n' > "$DIR/home/state/$id.status"
  printf '%s' "$DIR/wt" > "$DIR/fake/cwd"
  printf '%s' '%none' > "$DIR/fake/herdr-pane"   # nothing answers to %7 any more
  : > "$DIR/fake/herdr-log"
  herdr_stub "$DIR/fakebin"
}

fm() {  # <script> <args...>
  local script=$1; shift
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
      -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
      PATH="$DIR/fakebin:$PATH" FM_HOME="$DIR/home" FM_FAKE_DIR="$DIR/fake" \
      HOME="$DIR/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
      FM_GATE_REFUSE_BYPASS=1 \
      FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
      "$ROOT/bin/$script" "$@" 2>&1 | grep -v '^warning: .*records no delivery contract line'
  return "${PIPESTATUS[0]}"
}

aftermath() {  # <id>
  local id=$1
  echo
  echo "  the task afterwards:"
  grep -E '^(window|herdr_session|herdr_pane_id|herdr_tab_id)=' "$DIR/home/state/$id.meta" | sed 's/^/    record: /'
  printf '    worktree HEAD unchanged:  %s\n' \
    "$([ "$(git -C "$DIR/wt" rev-parse HEAD)" = "$HEAD_BEFORE" ] && echo yes || echo 'NO')"
  printf '    branch:                   %s\n' "$(git -C "$DIR/wt" rev-parse --abbrev-ref HEAD)"
  printf '    uncommitted change:       %s\n' \
    "$([ -f "$DIR/wt/dirty.txt" ] && cat "$DIR/wt/dirty.txt" || echo 'LOST')"
  printf '    status log:               %s\n' "$(tail -1 "$DIR/home/state/$id.status")"
  printf '    progress note in brief:   %s\n' \
    "$(grep -q 'pick the work back up' "$DIR/home/data/$id/brief.md" && echo 'delivered to the replacement' || echo 'not present')"
}

echo "=============================================================================="
echo " $LABEL"
echo " firstmate code root: $ROOT"
echo " commit:              $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "(tree extracted with git archive)")"
echo "=============================================================================="
echo
echo "A ship task parked on a no-mistakes approval. Its recorded herdr endpoint"
echo "fmlab:%7 was destroyed in churn; the fmlab server is still running and"
echo "answers pane_not_found for %7. Its worktree holds 1 commit + 1 uncommitted"
echo "file. Each attempt below starts from a fresh copy of exactly that state."

echo
echo "------------------------------------------------------------------------------"
echo " 1. Stop the agent, as the relaunch refusal tells the operator to"
echo "------------------------------------------------------------------------------"
new_stranded_case fmzeela
printf '\n$ bin/fm-control.sh fmzeela exit\n'
fm fm-control.sh fmzeela exit; printf '  -> exit %s\n' "$?"
aftermath fmzeela

echo
echo "------------------------------------------------------------------------------"
echo " 2. Relaunch directly, as the exit refusal leaves the operator to"
echo "------------------------------------------------------------------------------"
new_stranded_case fmzeelb
printf '\n$ bin/fm-spawn.sh fmzeelb --relaunch --harness claude\n'
fm fm-spawn.sh fmzeelb --relaunch --harness claude; printf '  -> exit %s\n' "$?"
aftermath fmzeelb

echo
echo "------------------------------------------------------------------------------"
echo " 3. The supported reclaim verb: control-plane relaunch with a progress note"
echo "------------------------------------------------------------------------------"
new_stranded_case fmzeelc
printf '\n$ bin/fm-control.sh fmzeelc relaunch --note "the pane was destroyed; pick the work back up"\n'
fm fm-control.sh fmzeelc relaunch --note 'the pane was destroyed; pick the work back up'
printf '  -> exit %s\n' "$?"
aftermath fmzeelc
echo
echo "  herdr calls the reclaim made (all scoped to the RECORDED session fmlab):"
sort -u "$DIR/fake/herdr-log" | grep -E '^(workspace|tab|pane send-text|agent get|pane get)' | sed 's/^/    /'
