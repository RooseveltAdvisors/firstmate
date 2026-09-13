#!/usr/bin/env bash
# Manual evidence run: real fm-spawn.sh against real herdr 0.9.0 in an
# isolated lab session, showing the opt-in human-readable task-tab label
# (and the default-off fm-<id> label) exactly as an operator sees it.
set -eu
ROOT=/home/jon/.no-mistakes/worktrees/16b9fb59e3d9/01M2CN4MTPFE945V9Q3RKJYHFR
EV=/home/jon/.no-mistakes/evidence/01M2CN4MTPFE945V9Q3RKJYHFR
OUT=$EV/manual-label-demo.transcript.txt

# shellcheck source=/dev/null
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-evidence-$$"
export HERDR_SESSION="$SESSION"
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-evidence.XXXXXX")
echo "lab root: $TMP_ROOT"
cleanup() {
  herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
fm_herdr_lab_prepare "$SESSION" >/dev/null

make_project() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Evidence' -c user.email='ev@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}

echo "# Manual evidence: herdr task-tab labels via real fm-spawn + real herdr 0.9.0" > "$OUT"
echo "# session: $SESSION (isolated lab; stopped and deleted at end)" >> "$OUT"

# Home A: opted in to human-readable labels via config/herdr-task-titles (empty file = presence opt-in)
HOME_A="$TMP_ROOT/home-a"
mkdir -p "$HOME_A/state" "$HOME_A/data/hired" "$HOME_A/config"
printf 'off\n' > "$HOME_A/config/herdr-presentation-spaces"
printf '' > "$HOME_A/config/herdr-task-titles"
cat > "$HOME_A/data/hired/brief.md" <<'BRIEF'
# Task
## Captain's intent
Fix herdr tab labels for the crew.

## Firstmate spec
Label check for evidence run.
BRIEF

# Home B: unconfigured (default off)
HOME_B="$TMP_ROOT/home-b"
mkdir -p "$HOME_B/state" "$HOME_B/data/plain" "$HOME_B/config"
printf 'off\n' > "$HOME_B/config/herdr-presentation-spaces"
cat > "$HOME_B/data/plain/brief.md" <<'BRIEF'
# Task
## Captain's intent
Default legacy labeling check.

## Firstmate spec
Label check for evidence run.
BRIEF

PROJ="$TMP_ROOT/scratch-project"
make_project "$PROJ"

spawn() { # <id> <home>
  FM_SPAWN_NO_GUARD=1 FM_HOME="$2" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$1" "$PROJ" "sh -c 'echo evidence-ok'" \
    --mode no-mistakes --yolo off --backend herdr >/dev/null 2>"$TMP_ROOT/$1.err" || {
      echo "spawn $1 failed rc=$?"
      cat "$TMP_ROOT/$1.err"
      exit 1
    }
}
spawn hired "$HOME_A"
spawn plain "$HOME_B"

# Read the REAL tab labels back from the real herdr CLI, as an operator would.
{
  echo
  echo "== herdr tab list (real CLI), workspace 'firstmate' =="
  WSID=$(herdr workspace list --session "$SESSION" | jq -r '.result.workspaces[] | select(.label=="firstmate") | .workspace_id')
  herdr tab list --workspace "$WSID" --session "$SESSION"
  echo
  echo "== operator-visible summary =="
  for id in hired plain; do
    case $id in
      hired) meta="$HOME_A/state/$id.meta" ;;
      plain) meta="$HOME_B/state/$id.meta" ;;
    esac
    tab=$(grep '^herdr_tab_id=' "$meta" | cut -d= -f2-)
    label=$(herdr tab list --workspace "$WSID" --session "$SESSION" | jq -r --arg t "$tab" '.result.tabs[]? | select(.tab_id==$t) | .label')
    meta_label=$(grep '^herdr_task_label=' "$meta" | cut -d= -f2-)
    echo "task $id: live tab label = [$label]; meta herdr_task_label = [$meta_label]"
  done
  echo
  echo "== label history sidecar (home-a, opted in) =="
  cat "$HOME_A/state/hired.herdr-task-labels"
  echo "(home-b unconfigured sidecar:) $(cat "$HOME_B/state/plain.herdr-task-labels" 2>/dev/null || echo absent)"
} >> "$OUT" 2>&1

cat "$OUT"
