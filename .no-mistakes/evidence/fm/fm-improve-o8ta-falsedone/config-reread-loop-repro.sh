#!/usr/bin/env bash
# Reproduction driver for the config-reread loop (bead fm-o8ta, defect 1).
#
# Usage: ROOT=<firstmate-checkout> bash config-reread-loop-repro.sh <label>
#
# Builds a real primary firstmate home + one live secondmate home, then drives
# the real `bin/fm-config-push.sh` CLI four times while the live secondmate
# drifts its own gitignored config/crew-harness between pushes - the exact
# shape that produced "3 byte-identical CONFIG_REREAD pushes in 3 minutes".
# Prints the operator-visible push output and every CONFIG_REREAD message the
# live agent actually received in its steering inbox.
set -u
LABEL=${1:-run}
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/fixtures.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-reread-repro)
export FM_BACKEND=tmux

w="$TMP_ROOT/world"
mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
touch "$w/home/state/.last-watcher-beat"
git init -q -b main "$w/main"
printf 'projects/\nstate/\ndata/\n.no-mistakes/\nconfig/crew-harness\nconfig/secondmate-harness\nconfig/backlog-backend\nconfig/backend\nconfig/herdr-presentation-spaces\nconfig/startup-memory-budget\nconfig/claude-permission-mode\nconfig/crew-dispatch.json\n' > "$w/main/.gitignore"
printf 'v1\n' > "$w/main/AGENTS.md"
printf 'r1\n' > "$w/main/README.md"
mkdir -p "$w/main/bin"
printf 'echo a\n' > "$w/main/bin/tool.sh"
git -C "$w/main" add -A
git -C "$w/main" commit -qm c1
head=$(git -C "$w/main" rev-parse HEAD)
git -C "$w/main" worktree add -q --detach "$w/sm" "$head"
printf 'sm\n' > "$w/sm/.fm-secondmate-home"
{ printf 'window=firstmate:fm-sm\n'; printf 'kind=secondmate\n'; printf 'home=%s/sm\n' "$w"; } > "$w/home/state/sm.meta"
mkdir -p "$w/sm/config" "$w/sm/state"

fakebin="$w/fakebin"; mkdir -p "$fakebin"
fm_fake_exit0 "$fakebin" node chrome-devtools-axi
fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
for t in gh-axi gh treehouse no-mistakes tasks-axi quota-axi; do
  printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && { printf "0.1.29\\n"; exit 0; }\nexit 0\n' > "$fakebin/$t"
  chmod +x "$fakebin/$t"
done
cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  list-windows*) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta; exit 0 ;;
  *display-message*'#{pane_current_command}'*) printf '%s\n' codex; exit 0 ;;
  *display-message*'#{pane_id}'*) printf '%s\n' '%1'; exit 0 ;;
  *display-message*'#{cursor_y}'*) printf '%s\n' 0; exit 0 ;;
  *capture-pane*) printf '❯\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$fakebin/tmux"

push() {
  PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    FM_SEND_SETTLE=0 "$ROOT/bin/fm-config-push.sh" 2>&1
}
inbox() {
  local rec
  for rec in "$w/home/state/sm.inbox"/*.msg; do
    [ -e "$rec" ] || continue
    bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$rec"
    printf '\n'
  done
}

printf '########## %s ##########\n' "$LABEL"
printf 'primary config/crew-harness = codex ; secondmate starts at "old"\n\n'
printf 'codex\n' > "$w/home/config/crew-harness"
printf 'old\n' > "$w/sm/config/crew-harness"

for round in 1 2 3 4; do
  if [ "$round" -gt 1 ]; then
    # The live secondmate edits its own gitignored config (expected local drift).
    printf 'pi\n' > "$w/sm/config/crew-harness"
    printf -- '--- minute %s: secondmate drifted its own config/crew-harness to "pi" ---\n' "$round"
  else
    printf -- '--- minute 1: first push of a genuinely new value ---\n'
  fi
  printf '$ fm-config-push.sh\n'
  push | sed 's/^/    /'
  printf '\n'
done

# Control: a genuinely NEW primary value must still reach the live agent.
printf -- '--- minute 5: captain changes the primary value codex -> grok (a real change) ---\n'
printf 'grok\n' > "$w/home/config/crew-harness"
printf '$ fm-config-push.sh\n'
push | sed 's/^/    /'
printf '\n'

printf '===== CONFIG_REREAD messages actually delivered to the live secondmate =====\n'
n=0
while IFS= read -r line; do
  case "$line" in
    *CONFIG_REREAD:*)
      n=$((n + 1))
      path=${line##*CONFIG_REREAD: }
      printf '[%s] %s\n' "$n" "$line"
      printf '      payload bytes:\n'
      sed 's/^/        | /' "$path"
      ;;
  esac
done < <(inbox)
printf '\nTOTAL CONFIG_REREAD messages the live agent received: %s\n' "$n"
printf 'final secondmate config/crew-harness: %s\n' "$(cat "$w/sm/config/crew-harness")"
