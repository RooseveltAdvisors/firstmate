#!/usr/bin/env bash
# Supervisor delegation: project denial, outage allowlist, and hook transports.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TDIR=$(fm_test_tmproot fm-jev-guard-test)
SUPERVISOR="$TDIR/home"
mkdir -p "$SUPERVISOR/bin" "$SUPERVISOR/projects/portal"
touch "$SUPERVISOR/AGENTS.md"
cp "$ROOT/bin/fm-jev-guard.sh" "$ROOT/bin/fm-jev-guard.py" "$SUPERVISOR/bin/"
export FM_ROOT_OVERRIDE="$SUPERVISOR" FM_HOME="$SUPERVISOR" FM_TEST_PRIMARY=1
export FM_JEV_PROXY_BIN="$TDIR/unavailable"
GUARD="$SUPERVISOR/bin/fm-jev-guard.sh"

assert_denied() {
  local command=$1 rc=0 output
  output=$("$GUARD" --command "$command" 2>&1) || rc=$?
  assert_equals 2 "$rc" "project command denied: $command"
  assert_contains "$output" require_delegation "deny explains delegation"
}

# The eight acceptance cases are deterministic even when Jev is unavailable.
for command in \
  'cd /opt/ra/firstmate/projects/portal && pytest tests/ -q' \
  'git -C projects/portal commit -m x' \
  'cd projects/portal && npm test'; do
  assert_denied "$command"
done
for command in \
  'bin/fm-wake-drain.sh' \
  'bd show x' \
  'herdr --session firstmate agent read w1:p1' \
  'bin/fm-spawn.sh --help' \
  'bin/fm-send.sh --help'; do
  "$GUARD" --command "$command" || fail "supervisor command denied: $command"
done
pass 'eight project/supervisor acceptance cases'
"$GUARD" --command "(cd /home/jon/git/wiseman && bd comment x 'run project tests')"

# Quoted worker instructions remain opaque, including systemd/project words.
"$GUARD" --command "bin/fm-send.sh worker 'cd projects/portal && npm test; systemctl restart app'"
"$GUARD" --command 'FM_HOME=/opt/ra/firstmate bash bin/fm-route-dispatch.sh --task "fix project tests"'
"$GUARD" --command 'bin/fm-brief.sh --help'
"$GUARD" --command 'tasks-axi list'
"$GUARD" --command 'git -C projects/portal status --short'
"$GUARD" --command "bash -c 'cd /opt/ra/firstmate && bd show x'"
assert_denied 'bin/fm-send.sh --help; cd projects/portal && npm test'
assert_denied $'bin/fm-send.sh --help\npytest tests/ -q'
assert_denied $'bd show x # supervisory read\npytest tests/ -q'
assert_denied $'bd show x;\npytest tests/ -q'
# shellcheck disable=SC2016 # Literal substitution is input for the guard.
assert_denied 'X=$(python3 job.py) bin/fm-spawn.sh --help'
assert_denied 'git -C projects/portal diff --output=project.patch'
assert_denied 'bin/fm-send.shx worker task'
assert_denied 'python3 -c "print(1)"'
(cd "$SUPERVISOR/projects/portal" && assert_denied 'pytest tests/ -q')
mkdir -p "$TDIR/.treehouse/pool/1/project"
(cd "$TDIR/.treehouse/pool/1/project" && assert_denied 'bun test')

# An online Jev project_worker classification must override its allow answer.
cat > "$TDIR/proxy" <<'PROXY'
#!/usr/bin/env bash
printf '%s' "$FM_TEST_JEV_RESPONSE"
PROXY
chmod +x "$TDIR/proxy"
export FM_JEV_PROXY_BIN="$TDIR/proxy"
export FM_TEST_JEV_RESPONSE='{"answers":{"action":{"choice":"allow_supervisor"},"violation_noul":{"noul":0},"target_domain":{"choice":"project_worker"}}}'
(cd "$TDIR" && assert_denied 'pytest tests/ -q')
export FM_TEST_JEV_RESPONSE='{"answers":{"action":{"choice":"allow_supervisor"},"violation_noul":{"noul":0},"target_domain":{"choice":"supervisor"}}}'
(cd "$TDIR" && "$GUARD" --command 'cat state/task.status') || fail 'online supervisor decision denied'
# A malformed response or proxy error must fail closed.
export FM_TEST_JEV_RESPONSE='{}'
(cd "$TDIR" && assert_denied 'pytest tests/ -q')
printf '#!/usr/bin/env bash\nexit 1\n' > "$TDIR/proxy"
(cd "$TDIR" && assert_denied 'pytest tests/ -q')

# Both supervisor roles use the policy; disposable worker worktrees remain inert.
touch "$SUPERVISOR/.fm-secondmate-home"
assert_denied 'cd projects/portal && npm test'
"$GUARD" --command 'bin/fm-spawn.sh --help'
rm "$SUPERVISOR/.fm-secondmate-home"
FM_TEST_PRIMARY=0 FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-jev-guard.sh" --command 'cd projects/portal && npm test' \
  || fail 'linked worker worktree should remain inert'

# Exercise the public adapters with deterministic project commands.
payload='{"tool_name":"Bash","tool_input":{"command":"cd projects/portal && pytest tests/ -q"}}'
rc=0
out=$(printf '%s' "$payload" | "$GUARD" --claude 2>"$TDIR/claude.err") || rc=$?
assert_equals 2 "$rc" 'Claude exits 2'
assert_equals '' "$out" 'Claude stdout empty'
assert_contains "$(cat "$TDIR/claude.err")" '"permissionDecision":"deny"' 'Claude deny object'
out=$(printf '%s' "$payload" | "$GUARD" --cursor 2>"$TDIR/cursor.err")
assert_contains "$out" '"permission":"deny"' 'Cursor deny object'
rc=0
out=$(printf '%s' "$payload" | "$GUARD" 2>"$TDIR/hook.err") || rc=$?
assert_equals 2 "$rc" 'Pi/Grok/Codex shell adapter exits 2'
assert_contains "$out" '"decision":"deny"' 'shell adapter deny object'
pass 'all fm-jev-guard tests passed'
