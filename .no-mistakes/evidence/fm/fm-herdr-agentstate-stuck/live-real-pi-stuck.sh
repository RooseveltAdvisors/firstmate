#!/usr/bin/env bash
# Live: the bead's reported shape with the REAL pi binary in an fm-lab herdr
# session - pi under a nested interactive shell, /quit, record stays.
set -u
ROOT=${ROOT:?}
. "$ROOT/tests/herdr-test-safety.sh"; herdr_forget_inherited_pane
SESSION="fm-lab-realpi-$$"; export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-realpi.XXXX"); SCRATCH=$(cd "$SCRATCH" && pwd)
trap 'rm -rf "$SCRATCH"; herdr_safe_stop_and_delete "$SESSION"' EXIT
fm_herdr_lab_prepare "$SESSION" || exit 1
echo "# herdr $(herdr --version), pi $(pi --version 2>&1 | head -1), lab $SESSION"
HOME_DIR="$SCRATCH/home"; mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/rpi"
printf '# Task\n## Captain'"'"'s intent\nx\n\n## Firstmate spec\nx\n' > "$HOME_DIR/data/rpi/brief.md"
PROJ="$SCRATCH/proj"; WT="$SCRATCH/wt"; mkdir -p "$PROJ"
git -C "$PROJ" init -q; echo x > "$PROJ/R"; git -C "$PROJ" add R; git -C "$PROJ" -c user.name=t -c user.email=t@e.invalid commit -qm i
git -C "$PROJ" worktree add --quiet -b rpi "$WT"
. "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr
CR=$(fm_backend_herdr_container_ensure "$WT"); C=${CR%%$'\t'*}; SEED=${CR#*$'\t'}; WS=${C#*:}
read -r TAB P <<<"$(fm_backend_herdr_create_task "$C" fm-rpi "$WT" "$SEED")"
printf '%s\n' "window=$SESSION:$P" endpoint_task_id=rpi "worktree=$WT" "project=$PROJ" harness=pi kind=ship mode=no-mistakes yolo=off model=default effort=default backend=herdr "herdr_session=$SESSION" "herdr_workspace_id=$WS" "herdr_tab_id=$TAB" "herdr_pane_id=$P" > "$HOME_DIR/state/rpi.meta"
ctl() { env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=4 "$ROOT/bin/fm-control.sh" rpi "$@" 2>&1; }
reg() { herdr agent get "$P" --session "$SESSION" 2>&1 | jq -c '(.result.agent|{agent,agent_status}) // .error.code'; }
ps_() { fm_backend_herdr_pane_process_state "$SESSION" "$P"; }
show() { echo "[$1] reg=$(reg) process_state=$(ps_) pane_agent_state=$(fm_backend_herdr_pane_agent_state "$SESSION" "$P") agent_state=$(fm_backend_agent_state herdr "$SESSION:$P")"; }
fm_backend_herdr_send_text_line "$SESSION:$P" "bash --norc -i"; sleep 1
fm_backend_herdr_send_text_line "$SESSION:$P" "pi"; 
for _ in $(seq 1 40); do [ "$(ps_)" = agent ] && break; sleep 0.5; done; sleep 4
show "real pi running idle"
echo "--- clear-registration while real pi is live:"; ctl clear-registration; echo "rc=$?"; show "after refused clear"
herdr pane send-text "$P" '/quit' --session "$SESSION" >/dev/null; herdr pane send-keys "$P" Enter --session "$SESSION" >/dev/null
for _ in $(seq 1 40); do [ "$(ps_)" = shell ] && break; sleep 0.5; done; sleep 4
show "after /quit under nested shell"
echo "--- exit verb on stuck pane:"; ctl exit; echo "rc=$?"
echo "--- clear-registration on stuck pane:"; ctl clear-registration; echo "rc=$?"; show "after clear"
mkdir -p "$SCRATCH/fb"; printf '#!/usr/bin/env bash\n: > %q\n' "$SCRATCH/launched" > "$SCRATCH/fb/codex"; chmod +x "$SCRATCH/fb/codex"
fm_backend_herdr_send_text_line "$SESSION:$P" "export PATH=$SCRATCH/fb:\$PATH"; sleep 0.5
echo "--- relaunch:"; env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" rpi --relaunch --harness codex 2>&1 | tail -2; echo "rc=${PIPESTATUS[0]}"
for _ in $(seq 1 30); do [ -e "$SCRATCH/launched" ] && break; sleep 0.2; done
[ -e "$SCRATCH/launched" ] && echo "replacement harness launched on same endpoint: $(sed -n 's/^window=//p' "$HOME_DIR/state/rpi.meta" | tail -1)" || echo "replacement NOT launched"
fm_backend_herdr_kill "$SESSION:$P" 2>/dev/null || true
