#!/usr/bin/env bash
# Live product drive: the launch brief a lane receives fences the contribution
# ledger. Drives the REAL bin/fm-spawn.sh (which emits fm_brief_worker_role from
# bin/fm-dod-lib.sh into data/<id>/launch-brief.md and the harness prompt) in a
# fully disposable home with the repo's own fixture world: fake tmux captures
# the launch command, a fake codex harness captures the argv it is launched
# with, and the delivered prompt is decoded through bin/fm-operational-input.sh.
set -u
WT=/home/jon/.no-mistakes/worktrees/46339c0817e0/01M5Y1A4N1TAT4AA89M1E05CEH
EV=/home/jon/.no-mistakes/evidence/01M5Y1A4N1TAT4AA89M1E05CEH
T="$EV/07-scenario6-launch-brief-fences-the-ledger.log"
PROMPT_ART="$EV/07-scenario6-delivered-launch-prompt.md"
mkdir -p "$EV"; : > "$T"

say() { printf '%s\n' "$*" | tee -a "$T"; }
STATUS=0
check() {
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then say "PASS: $label"; else say "FAIL: $label"; STATUS=1; fi
}

# shellcheck source=tests/fixtures.sh
. "$WT/tests/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief-live)
CASE="$TMP_ROOT/case"
HOME_DIR="$CASE/home"
PROJ_DIR="$CASE/project"
WT_DIR="$CASE/wt"
LAUNCH_LOG="$CASE/launch.log"
ID=s6-fence
FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE/fake")

# Launch-resolution probes the real spawn runs before accepting a harness CLI.
cat > "$FAKEBIN_DIR/timeout" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -k ]; then shift 2; fi
shift
exec "$@"
SH
cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${FM_ROLE_PROMPT:-/dev/null}"
SH
chmod +x "$FAKEBIN_DIR/timeout" "$FAKEBIN_DIR/codex"

fm_test_spawn_home "$HOME_DIR" codex
fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$ID"

say "== Scenario 6: the launch brief a lane receives fences the contribution ledger =="
say "product path: bin/fm-brief.sh scaffolds the authored brief -> bin/fm-spawn.sh renders data/$ID/launch-brief.md (fm_brief_worker_role) -> harness launch command -> decoded worker prompt"

# Authored brief through the real scaffold, then the captain's task words.
FM_HOME="$HOME_DIR" "$WT/bin/fm-brief.sh" "$ID" arbitrary-project-name --mode no-mistakes > "$CASE/scaffold.log" 2>&1 \
  || { say "FAIL: brief scaffold failed: $(cat "$CASE/scaffold.log")"; echo "STATUS=1"; exit 1; }
brief="$HOME_DIR/data/$ID/brief.md"
content=$(cat "$brief")
content=${content//'{TASK}'/Settle the no-CI pull request so the contributions record stays machine-readable.}
content=${content//'{FIRSTMATE_SPEC}'/Fix the writer at its source; settlements must need no hand repair.}
printf '%s\n' "$content" > "$brief"

# Real fm-spawn.sh against the disposable home; fake tmux records the launch.
out=$(CLAUDE_CONFIG_DIR="" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="" \
  FM_FAKE_PI_VERSION=0.84.0 FM_FAKE_OPENCODE_VERSION=2.0.21 FM_FAKE_OPENCODE_TURN=auto \
  FM_FAKE_ENTER_LOG="" FM_OPENCODE_POLL_INTERVAL=0.01 FM_FAKE_CURSOR_MODELS="" \
  FM_FAKE_CURSOR_LIST_STATUS=0 GROK_HOME="$HOME_DIR/grok-home" \
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
  PATH="$FAKEBIN_DIR:$PATH" \
  "$WT/bin/fm-spawn.sh" "$ID" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
rc=$?
printf '$ fm-spawn.sh %s %s --mode no-mistakes --yolo off\n%s\n[exit %s]\n' "$ID" "$PROJ_DIR" "$out" "$rc" >> "$T"
check 'fm-spawn renders and launches (exit 0)' [ "$rc" -eq 0 ]
check 'spawn rendered data/<id>/launch-brief.md' [ -f "$HOME_DIR/data/$ID/launch-brief.md" ]

# Execute the captured launch command: the fake codex records its argv.
launch=$(cat "$LAUNCH_LOG")
envelope="$CASE/prompt-envelope"
FM_ROLE_PROMPT="$envelope" PATH="$FAKEBIN_DIR:$PATH" bash -c "$launch" \
  || { say "FAIL: could not consume launch command"; echo "STATUS=1"; exit 1; }
sed -n '/FIRSTMATE_OP: v1 launch-brief:/,$p' "$envelope" > "$CASE/encoded-prompt"
"$WT/bin/fm-operational-input.sh" body < "$CASE/encoded-prompt" > "$PROMPT_ART" \
  || { say "FAIL: could not decode launch-brief envelope"; echo "STATUS=1"; exit 1; }

say "delivered worker prompt saved to: $PROMPT_ART"
say '--- fence lines in the delivered prompt ---'
grep -n -A1 'contributions\.json\|observer owns its record' "$PROMPT_ART" | tee -a "$T"
say '--- end excerpt ---'
check 'delivered prompt fences the contribution ledger (observer ownership)' \
  grep -q "Every \`contributions.json\` record belongs to firstmate's contribution observer" "$PROMPT_ART"
check 'delivered prompt forbids hand-written records' \
  grep -q 'never create or edit one by hand' "$PROMPT_ART"
check 'delivered prompt names the PR reporting path that keeps the record machine-readable' \
  grep -q 'full https URL in your status line and final report' "$PROMPT_ART"
check 'the fence sits inside the worker role contract section' \
  bash -c 'awk "/^# Current worker role contract\$/{r=1} /^# Task\$/{r=0} r" "$1" | grep -q "never create or edit one by hand"' _ "$PROMPT_ART"
check 'authored brief was not rewritten by spawn' \
  bash -c 'grep -q "Settle the no-CI pull request" "$1/data/s6-fence/brief.md" && ! grep -q "Current worker role contract" "$1/data/s6-fence/brief.md"' _ "$HOME_DIR"

say ''
if [ "$STATUS" -eq 0 ]; then say 'ALL SCENARIO CHECKS PASSED'; else say 'SOME SCENARIO CHECKS FAILED'; fi
echo "STATUS=$STATUS"
exit "$STATUS"
