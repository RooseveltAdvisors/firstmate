#!/usr/bin/env bash
# Live validation of `fm-control.sh <id> clear-registration` against a REAL herdr
# server, in an isolated fm-lab-* session (bin/fm-herdr-lab.sh contract via
# tests/herdr-test-safety.sh). Modeled on tests/fm-control-herdr-smoke.test.sh.
set -u
ROOT=${ROOT:?}
fail() { printf 'not ok - %s\n' "$1"; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
SESSION="fm-lab-clearreg-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  [ -n "$SCRATCH" ] && chmod -R u+w "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fail() { printf 'not ok - %s\n' "$1"; exit 1; }
fm_herdr_lab_prepare "$SESSION" || fail "prepare lab"
echo "# herdr $(herdr --version) lab session $SESSION"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-clearreg.XXXXXX"); SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"; mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/creg"
printf '# Task\n## Captain'"'"'s intent\nx\n\n## Firstmate spec\nx\n' > "$HOME_DIR/data/creg/brief.md"
PROJ="$SCRATCH/proj"; WT="$SCRATCH/wt"; mkdir -p "$PROJ"
git -C "$PROJ" init -q; echo x > "$PROJ/R"; git -C "$PROJ" add R
git -C "$PROJ" -c user.name=t -c user.email=t@e.invalid commit -qm i
git -C "$PROJ" worktree add --quiet -b creg "$WT"

. "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr || fail "source herdr"
CR=$(fm_backend_herdr_container_ensure "$WT") || fail "container"
CONTAINER=${CR%%$'\t'*}; SEED=${CR#*$'\t'}; WS=${CONTAINER#*:}
read -r TAB_ID PANE_ID <<<"$(fm_backend_herdr_create_task "$CONTAINER" fm-creg "$WT" "$SEED")"
cat > "$HOME_DIR/state/creg.meta" <<EOF
window=$SESSION:$PANE_ID
endpoint_task_id=creg
worktree=$WT
project=$PROJ
harness=pi
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WS
herdr_tab_id=$TAB_ID
herdr_pane_id=$PANE_ID
EOF
ctl() { env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 "$ROOT/bin/fm-control.sh" creg "$@" 2>&1; }
reg() { herdr agent get "$PANE_ID" --session "$SESSION" 2>&1 | jq -c '.result.agent // .error | {agent,agent_status,code}'; }
pstate() { fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID"; }
wait_ps() { for _ in $(seq 1 80); do [ "$(pstate)" = "$1" ] && return 0; sleep 0.1; done; return 1; }
register() { herdr pane report-agent "$PANE_ID" --source fm-clearreg --agent fm-clearreg-agent --state idle --session "$SESSION" >/dev/null 2>&1 || fail "report-agent"; }
fgpid() { herdr pane process-info --pane "$PANE_ID" --session "$SESSION" | jq -r '.result.process_info.foreground_processes[0].pid // empty'; }

AB="$SCRATCH/agentbin"; mkdir -p "$AB"; ln -s "$(command -v sleep)" "$AB/pi"
start_agent() { fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "$AB/pi 900" || fail send; wait_ps agent || fail "not agent: $(pstate)"; }
# The reported stuck shape: an agent registered while its process ran, then the
# process exited and the pane fell back to an idle shell; the record stays.
make_stuck() { fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "bash --norc -i" || fail send; sleep 1; start_agent; register; kill "$(fgpid)"; wait_ps shell || fail "pane not shell"; sleep 3
  [ -n "$(herdr agent get "$PANE_ID" --session "$SESSION" 2>&1 | jq -r '.result.agent.agent // empty')" ] || fail "herdr released the registration; stuck shape not reproduced"; }
echo "## S1 stuck registration over idle shell (agent process exited, record kept)"
make_stuck
echo "registration: $(reg)  process_state=$(pstate)  pane_agent_state=$(fm_backend_herdr_pane_agent_state "$SESSION" "$PANE_ID")  agent_state=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")"
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")" = dead ] || fail "stuck reg not dead"
pass "S1 classifier: registration over agent-less shell reads dead"

echo "## S2 clear-registration on stuck pane (real pane.clear_agent_authority)"
OUT=$(ctl clear-registration); rc=$?; echo "\$ fm-control.sh creg clear-registration  -> rc=$rc"; echo "$OUT"
echo "registration after: $(reg)"
[ $rc = 0 ] && [[ "$OUT" == "cleared-registration creg "* ]] || fail "clear did not report cleared"
[ "$(herdr agent get "$PANE_ID" --session "$SESSION" 2>&1 | jq -r '.error.code // empty')" = agent_not_found ] || fail "registration still present"
herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null || fail "pane removed"
[ -d "$WT" ] || fail "worktree removed"
pass "S2 real server cleared the stuck registration; pane and worktree survive"

echo "## S3 idempotent"
OUT=$(ctl clear-registration); rc=$?; echo "rc=$rc $OUT"
[ $rc = 0 ] && [[ "$OUT" == "already-clear creg "* ]] || fail "not already-clear"
pass "S3 second clear is already-clear success"

echo "## S5 adversarial: foreground non-agent command + registration"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "sleep 900" || fail send
wait_ps other || fail "not other: $(pstate)"; register; sleep 2
echo "registration: $(reg) process_state=$(pstate) agent_state=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")"
OUT=$(ctl clear-registration); rc=$?; echo "rc=$rc $OUT"; echo "registration after: $(reg)"
[ $rc != 0 ] && [[ "$OUT" == *"foreground command or editor"* ]] || fail "foreground not refused"
[ -n "$(herdr agent get "$PANE_ID" --session "$SESSION" 2>&1 | jq -r '.result.agent.agent // empty')" ] || fail "registration stripped under foreground"
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")" != dead ] || fail "done-alone with foreground concluded dead"
pass "S5 foreground command refused; registration intact; classifier never concludes dead"
kill "$(fgpid)"; wait_ps shell || fail "fg stop"; sleep 2
R=$(ctl clear-registration) || fail "reset clear 2: $R ps=$(pstate) reg=$(reg)"

echo "## S4 adversarial: live agent process + registration"
start_agent; register
echo "registration: $(reg) process_state=$(pstate) agent_state=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")"
OUT=$(ctl clear-registration); rc=$?; echo "rc=$rc $OUT"; echo "registration after: $(reg)"
[ $rc != 0 ] && [[ "$OUT" == *"live agent process"* ]] || fail "live agent not refused"
[ "$(herdr agent get "$PANE_ID" --session "$SESSION" 2>&1 | jq -r '.result.agent.agent // empty')" = fm-clearreg-agent ] || fail "live registration was stripped"
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")" = alive ] || fail "live agent not alive"
pass "S4 live agent refused; registration intact; classifier still alive"
kill "$(fgpid)"; wait_ps shell || fail "agent stop"; sleep 2

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
