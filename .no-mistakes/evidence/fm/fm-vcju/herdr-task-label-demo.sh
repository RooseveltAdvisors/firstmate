#!/usr/bin/env bash
# Manual end-to-end demonstration of PR 3458's user-visible behavior:
# a newly spawned Herdr worker's tab carries "<short title> (<id>)" on a home
# that opted in through config/herdr-task-titles, and the historical "fm-<id>"
# on a home that has not.
#
# Drives the REAL bin/fm-spawn.sh against a REAL isolated Herdr lab session
# (never the captain's default session) and prints what the operator sees.
set -u
ROOT=${1:?usage: herdr-task-label-demo.sh <repo-root> <evidence-dir>}
EV=${2:?usage: herdr-task-label-demo.sh <repo-root> <evidence-dir>}

# shellcheck source=/dev/null
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane   # this shell runs inside a real Herdr pane

SESSION="fm-lab-tasklabel$$"
export HERDR_SESSION="$SESSION"
TMP=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-label-demo.XXXXXX")
VIEW_TMUX="fmlabel$$"
WT_LIST="$TMP/worktrees"
: > "$WT_LIST"

cleanup() {
  tmux kill-session -t "$VIEW_TMUX" 2>/dev/null || true
  while read -r wt; do
    [ -n "$wt" ] && treehouse return --force "$wt" >/dev/null 2>&1
  done < "$WT_LIST"
  fm_herdr_lab_viewer_stop "$SESSION" >/dev/null 2>&1 || true
  fm_herdr_lab_teardown "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

fm_herdr_lab_provision "$SESSION" || { echo "could not provision lab session"; exit 1; }

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
# Flat placement so both workers share one workspace and one visible tab bar.
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"

PROJ="$TMP/project"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# demo\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Demo' -c user.email='demo@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

# A real tasks-axi backlog: the titles below are the operator-authored titles
# the new label is derived from.
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
tasks-axi add porch-rail "Fix the porch railing before winter" --file="$HOME_DIR/data/backlog.md" >/dev/null
tasks-axi add shed-paint "Paint the garden shed" --file="$HOME_DIR/data/backlog.md" >/dev/null

write_brief() {  # <id> <intent>
  mkdir -p "$HOME_DIR/data/$1"
  cat > "$HOME_DIR/data/$1/brief.md" <<EOF
# Task
## Captain's intent
$2

## Firstmate spec
Demonstrate the Herdr task-tab label an operator sees.
EOF
}
write_brief porch-rail 'Fix the porch railing before winter.'
write_brief shed-paint 'Paint the garden shed.'

spawn() {  # <id>
  FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$1" "$PROJ" "sh -c 'echo worker-$1-running; sleep 900'" \
    --mode no-mistakes --yolo off --backend herdr >"$TMP/$1.out" 2>"$TMP/$1.err"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "SPAWN FAILED ($1)"; sed -n '1,40p' "$TMP/$1.out" "$TMP/$1.err"; exit 1
  fi
  grep '^worktree=' "$HOME_DIR/state/$1.meta" | cut -d= -f2- >> "$WT_LIST"
}

echo "=============================================================================="
echo "1. This home OPTS IN:  touch config/herdr-task-titles"
echo "=============================================================================="
printf '' > "$HOME_DIR/config/herdr-task-titles"
ls -l "$HOME_DIR/config/herdr-task-titles" | sed 's#'"$HOME_DIR"'#<home>#'
echo
echo "   backlog row being dispatched:"
tasks-axi show porch-rail --file="$HOME_DIR/data/backlog.md" 2>/dev/null | sed -n '1,8p'
echo
spawn porch-rail
echo "   spawned. state/porch-rail.meta records:"
grep -E '^(backend|herdr_tab_id|herdr_pane_id|herdr_task_label)=' "$HOME_DIR/state/porch-rail.meta"
echo

echo "=============================================================================="
echo "2. The SAME home stands the flag down:  rm config/herdr-task-titles"
echo "=============================================================================="
rm -f "$HOME_DIR/config/herdr-task-titles"
spawn shed-paint
echo "   spawned. state/shed-paint.meta records:"
grep -E '^(backend|herdr_tab_id|herdr_pane_id|herdr_task_label)=' "$HOME_DIR/state/shed-paint.meta"
echo

WSID=$(herdr pane get "$(grep '^herdr_pane_id=' "$HOME_DIR/state/porch-rail.meta" | cut -d= -f2-)" \
  --session "$SESSION" | jq -r '.result.pane.workspace_id')
echo "=============================================================================="
echo "3. What Herdr itself reports for this home's workspace ($WSID)"
echo "=============================================================================="
herdr tab list --workspace "$WSID" --session "$SESSION" \
  | jq -r '.result.tabs[] | "  tab \(.tab_id)   label: \(.label)"'
echo
echo "   (the opted-in worker's tab now names its backlog title;"
echo "    the stood-down worker's tab keeps the historical fm-<id>)"
echo

echo "=============================================================================="
echo "4. Live tab labels as recovery/orphan discovery sees them"
echo "=============================================================================="
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
FM_HOME="$HOME_DIR" fm_backend_herdr_list_live "$SESSION" | sed 's/^/  /'
echo

echo "=============================================================================="
echo "5. The real Herdr TUI an operator looks at"
echo "=============================================================================="
tmux kill-session -t "$VIEW_TMUX" 2>/dev/null || true
tmux new-session -d -s "$VIEW_TMUX" -x 120 -y 40 \
  "env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH -u HERDR_BIN_PATH TERM=xterm-256color herdr --session $SESSION"
sleep 6
tmux capture-pane -p -t "$VIEW_TMUX" > "$EV/herdr-tui-tab-bar.txt"
tmux capture-pane -p -e -t "$VIEW_TMUX" > "$TMP/tui.ansi"
cp "$TMP/tui.ansi" "$EV/herdr-tui-tab-bar.ansi"
cat "$EV/herdr-tui-tab-bar.txt"
tmux kill-session -t "$VIEW_TMUX" 2>/dev/null || true

echo
echo "=============================================================================="
echo "6. Teardown removes the label sidecar with the rest of the task state"
echo "=============================================================================="
ls "$HOME_DIR/state" | grep -E 'herdr-task-labels' || echo "  (label history already compacted/absent)"
for id in porch-rail shed-paint; do
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-teardown.sh" "$id" >"$TMP/td-$id.out" 2>&1 \
    || { echo "teardown failed for $id"; sed -n '1,30p' "$TMP/td-$id.out"; }
done
echo "  state/ after teardown:"
ls -A "$HOME_DIR/state" | sed 's/^/    /' || true
: > "$WT_LIST"
echo
echo "demo complete"
