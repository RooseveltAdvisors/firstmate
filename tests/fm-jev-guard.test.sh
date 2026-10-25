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
"$GUARD" --command 'bd show x 2>&1' || fail 'fd-dup redirect denied: bd show x 2>&1'
"$GUARD" --command 'gh pr view 7' || fail 'supervisor command denied: gh pr view 7'
assert_denied 'gh pr merge 7'
assert_denied 'git log &> /tmp/out'
assert_denied 'bd list >& /tmp/out'
assert_denied 'git show x >| /tmp/out'
"$GUARD" --command 'bd list > /dev/null' || fail 'outage contract denies discard sink'
assert_denied 'bd list > /tmp/out'
assert_denied 'bd list > /dev/fd/9'
assert_denied 'bd list > /dev/nullx'
assert_denied 'bd list > /dev/null/x'
"$GUARD" --command "(cd /home/jon/git/wiseman && bd comment x 'run project tests')"

# Quoted worker instructions stay opaque, including systemd/project words;
# shell-substitution tokens are refused rather than passed through.
"$GUARD" --command "bin/fm-send.sh worker 'cd projects/portal && npm test; systemctl restart app'"
"$GUARD" --command 'FM_HOME=/opt/ra/firstmate bash bin/fm-route-dispatch.sh --task "fix project tests"'
"$GUARD" --command 'bin/fm-brief.sh --help'
"$GUARD" --command 'tasks-axi list'
"$GUARD" --command 'git -C projects/portal status --short'
"$GUARD" --command "bash -c 'cd /opt/ra/firstmate && bd show x'"
"$GUARD" --command "bash -ec 'bd show x'" || fail 'supervisor payload denied: bash -ec'
"$GUARD" --command "bash -euo pipefail -c 'bd show x'" || fail 'supervisor payload denied: bash -euo pipefail -c'
"$GUARD" --command "zsh -c 'bd show x'" || fail 'supervisor payload denied: zsh -c'
"$GUARD" --command "bash -O extglob -c 'bd show x'" || fail 'supervisor payload denied: bash -O extglob -c'
"$GUARD" --command "sh -ec 'bd show x'" || fail 'supervisor payload denied: sh -ec'
"$GUARD" --command "zsh -eu -c 'bd show x'" || fail 'supervisor payload denied: zsh -eu -c'
"$GUARD" --command "dash -e -c 'bd show x'" || fail 'supervisor payload denied: dash -e -c'
assert_denied 'bd show "unterminated'
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
[ -n "${FM_TEST_QUERY_LOG:-}" ] && echo tick >> "$FM_TEST_QUERY_LOG"
printf '%s' "$FM_TEST_JEV_RESPONSE"
PROXY
chmod +x "$TDIR/proxy"
export FM_JEV_PROXY_BIN="$TDIR/proxy"
export FM_TEST_JEV_RESPONSE='{"answers":{"action":{"choice":"allow_supervisor"},"violation_noul":{"noul":0},"target_domain":{"choice":"project_worker"}}}'
(cd "$TDIR" && assert_denied 'pytest tests/ -q')
export FM_TEST_JEV_RESPONSE='{"answers":{"action":{"choice":"allow_supervisor"},"violation_noul":{"noul":0},"target_domain":{"choice":"supervisor"}}}'
export FM_TEST_QUERY_LOG="$TDIR/queries"
(cd "$TDIR" && "$GUARD" --command 'cat state/task.status') || fail 'online supervisor decision denied'
(cd "$TDIR" && "$GUARD" --command 'cat state/task.status') || fail 'repeated supervisor decision denied'
assert_equals 2 "$(wc -l < "$TDIR/queries" | tr -d '[:space:]')" 'Jev decisions are never cached'
unset FM_TEST_QUERY_LOG
out=$(cd "$SUPERVISOR" && python3 "$SUPERVISOR/bin/fm-jev-guard.py" --json --command 'bd list > /dev/null')
assert_contains "$out" '"code": "fast_path_whitelist"' 'discard sink keeps the fast path'
assert_contains "$out" '"tier": 1' 'discard sink is tier 1'
# A project path the command only mentions reaches Jev; one it operates on is
# denied before the query even when Jev would allow it.
for command in \
  'pgrep -f projects/portal' \
  'grep -l projects/portal state/*.status' \
  "bash -c 'grep projects/portal state/x'" \
  "find . -path 'projects/portal*'" \
  "find . -name 'projects*'" \
  "find . \( -path 'projects/portal*' -o -name x \)" \
  "echo projects/portal" \
  "bash -ec 'pgrep -f projects/portal'" \
  "zsh -c 'grep -l projects/portal state/x'" \
  'bash -c "rm state/x'; do
  out=$(cd "$SUPERVISOR" && python3 "$SUPERVISOR/bin/fm-jev-guard.py" --check-only --command "$command")
  assert_contains "$out" supervisor_approved "mention-only project path reaches Jev: $command"
done
for command in \
  'cd projects/portal && npm test' \
  'git -C projects/portal commit -m x' \
  "bash -c 'cd projects/portal && npm test'" \
  'find projects/portal -type f' \
  'touch projects/portal/new-file' \
  'echo x > projects/portal/app.py' \
  "bash -c 'cat > projects/portal/new.py'" \
  'test -d projects/portal' \
  "touch 'projects/portal/new file'" \
  "cp state/task.status 'projects/portal/new file'" \
  'find . -path "./projects/*" -delete' \
  "find . -path './projects/*' -exec rm {} +" \
  'tar -Cprojects/portal -cf /tmp/x .' \
  'awk -f projects/portal/rules.awk state/task.status' \
  'grep -f projects/portal/patterns state/x.status' \
  'find . -fls projects/portal/listing' \
  'find . -fprintf projects/portal/out %s' \
  'find . -fprint projects/portal/listing' \
  'find . -fprint0 projects/portal/listing0' \
  'find . -okdir rm projects/portal/x {} +' \
  'find . -fls > projects/portal/out' \
  "find . -path './projects/*' \( -name x -o -name y \) -delete" \
  "find . \( -path './projects/*' -o -name '*.bak' \) -exec rm {} +" \
  "find . \( -fprint projects/portal/listing \)" \
  "find . -exec rm projects/portal/x {} \; -fprint projects/portal/listing" \
  "bash -ec 'rm projects/portal/x'" \
  "bash -euc 'rm projects/portal/x'" \
  "bash -euo pipefail -c 'rm projects/portal/x'" \
  "bash -o errexit -c 'rm projects/portal/x'" \
  "/bin/bash -ec 'rm projects/portal/x'" \
  "env F=1 bash -ec 'rm projects/portal/x'" \
  "zsh -c 'rm projects/portal/x'" \
  "dash -c 'rm projects/portal/x'" \
  "find . -execdir bash -c 'rm projects/portal/x' {} +" \
  "bash -O extglob -c 'rm projects/portal/x'" \
  "sh -ec 'rm projects/portal/x'" \
  "zsh -eu -c 'rm projects/portal/x'" \
  "dash -e -c 'rm projects/portal/x'" \
  "find . -exec bash -c 'rm projects/portal/x' {} +" \
  "find . -ok sh -c 'rm projects/portal/x' {} \;" \
  'bash -c "rm projects/portal/x' \
  'projects/portal/bin/tool arg' \
  "sh -c 'cat \"\$1\"' _ projects/portal/x" \
  "ksh -c 'rm projects/portal/x'" \
  "ash -c 'rm projects/portal/x'"; do
  out=$(cd "$SUPERVISOR" && python3 "$SUPERVISOR/bin/fm-jev-guard.py" --check-only --command "$command")
  assert_contains "$out" 'Project work must be delegated' "operative project path pre-denied: $command"
done
# Written amendment: the nine wrapper words peel before the shell-name check, and
# the pre-deny fires before any query under either Jev answer shape.
for wrapper in nohup env 'env -i' 'env -u FOO' 'env -U FOO' 'env -uFOO' 'env --unset=FOO' timeout 'timeout 5' exec nice 'nice -n 5' setsid 'setsid -f' xargs 'xargs -I{}' 'xargs -n1' time 'time -p' command; do
  for answer in \
    '{"answers":{"action":{"choice":"require_delegation"},"violation_noul":{"noul":1},"target_domain":{"choice":"project_worker"}}}' \
    '{"answers":{"action":{"choice":"allow_supervisor"},"violation_noul":{"noul":0},"target_domain":{"choice":"supervisor"}}}'; do
    export FM_TEST_JEV_RESPONSE="$answer"
    out=$(cd "$SUPERVISOR" && python3 "$SUPERVISOR/bin/fm-jev-guard.py" --check-only --command "$wrapper bash -c 'rm projects/portal/x'")
    assert_contains "$out" 'Project work must be delegated' "wrapper $wrapper pre-denies before any query"
  done
  export FM_TEST_JEV_RESPONSE='{"answers":{"action":{"choice":"allow_supervisor"},"violation_noul":{"noul":0},"target_domain":{"choice":"supervisor"}}}'
  out=$(cd "$SUPERVISOR" && python3 "$SUPERVISOR/bin/fm-jev-guard.py" --check-only --command "$wrapper bash -c 'cat state/task.status'")
  assert_contains "$out" supervisor_approved "wrapper $wrapper benign payload reaches the normal path"
done
out=$(cd "$SUPERVISOR" && python3 "$SUPERVISOR/bin/fm-jev-guard.py" --check-only --command "ksh -c 'bd show x'")
assert_contains "$out" supervisor_approved 'ksh payload form leaves the fast path'
assert_not_contains "$out" fast_path_whitelist 'ksh payload form is not fast-path'
out=$(cd "$SUPERVISOR" && python3 "$SUPERVISOR/bin/fm-jev-guard.py" --check-only --command "ash -c 'bd list'")
assert_contains "$out" supervisor_approved 'ash payload form leaves the fast path'
assert_not_contains "$out" fast_path_whitelist 'ash payload form is not fast-path'
out=$(cd "$SUPERVISOR" && python3 "$SUPERVISOR/bin/fm-jev-guard.py" --json --command "bin/fm-send.sh worker 'touch projects/portal/new.py'")
assert_contains "$out" '"code": "fast_path_whitelist"' 'task payload fast-passes with its allowlisted tool'
# Second written amendment: file-valued wrapper options are operands in their
# own right, in addition to the peel reaching the payload.
for probe in \
  'time -o projects/portal/out.log ls' \
  'time --output=projects/portal/out.log ls' \
  'xargs -a projects/portal/data echo hi' \
  'xargs --arg-file=projects/portal/data echo' \
  "time -o out sh -c 'rm projects/portal/x'" \
  "xargs -I{} sh -c 'rm projects/portal/x'" \
  'ls projects/portal/out.log'; do
  for answer in \
    '{"answers":{"action":{"choice":"require_delegation"},"violation_noul":{"noul":1},"target_domain":{"choice":"project_worker"}}}' \
    '{"answers":{"action":{"choice":"allow_supervisor"},"violation_noul":{"noul":0},"target_domain":{"choice":"supervisor"}}}'; do
    export FM_TEST_JEV_RESPONSE="$answer"
    out=$(cd "$SUPERVISOR" && python3 "$SUPERVISOR/bin/fm-jev-guard.py" --check-only --command "$probe")
    assert_contains "$out" 'Project work must be delegated' "file-valued wrapper option pre-denies: $probe"
  done
done
export FM_TEST_JEV_RESPONSE='{"answers":{"action":{"choice":"allow_supervisor"},"violation_noul":{"noul":0},"target_domain":{"choice":"supervisor"}}}'
out=$(cd "$SUPERVISOR" && python3 "$SUPERVISOR/bin/fm-jev-guard.py" --check-only --command 'time -o /tmp/x ls')
assert_not_contains "$out" 'Project work must be delegated' 'non-project file value is not pre-denied'
assert_not_contains "$out" fast_path_whitelist 'non-project file value gains no fast path'
assert_contains "$out" supervisor_approved 'non-project file value reaches Jev'
# Inbox017: assignment values that resolve under projects/ refuse the fast path
# and pre-deny; the expansion remainder keeps reaching Jev.
for probe in \
  "BASH_ENV=projects/portal/evil.sh bash -c 'bd show x'" \
  "env BASH_ENV=projects/portal/evil.sh bash -c 'bd show x'" \
  "LD_PRELOAD=projects/portal/x.so bd show x" \
  "GIT_EXTERNAL_DIFF=projects/portal/x git diff"; do
  for answer in \
    '{"answers":{"action":{"choice":"require_delegation"},"violation_noul":{"noul":1},"target_domain":{"choice":"project_worker"}}}' \
    '{"answers":{"action":{"choice":"allow_supervisor"},"violation_noul":{"noul":0},"target_domain":{"choice":"supervisor"}}}'; do
    export FM_TEST_JEV_RESPONSE="$answer"
    out=$(cd "$SUPERVISOR" && python3 "$SUPERVISOR/bin/fm-jev-guard.py" --check-only --command "$probe")
    assert_contains "$out" 'Project work must be delegated' "assignment value pre-denies: $probe"
  done
done
export FM_TEST_JEV_RESPONSE='{"answers":{"action":{"choice":"allow_supervisor"},"violation_noul":{"noul":0},"target_domain":{"choice":"supervisor"}}}'
out=$(cd "$SUPERVISOR" && python3 "$SUPERVISOR/bin/fm-jev-guard.py" --check-only --command 'FOO=bar bd show x')
assert_contains "$out" fast_path_whitelist 'benign assignment keeps the fast path'
for probe in 'D=projects/portal; rm $D/x' 'P=projects/portal; cd $P && npm test' 'rm proj*/x'; do
  out=$(cd "$SUPERVISOR" && python3 "$SUPERVISOR/bin/fm-jev-guard.py" --check-only --command "$probe")
  assert_contains "$out" supervisor_approved "expansion form still reaches Jev: $probe"
  assert_not_contains "$out" 'Project work must be delegated' "expansion form is not pre-denied: $probe"
done
# Inbox014: generic value consumption reaches the payload in every wrapper form.
for probe in \
  "xargs --max-args 1 bash -c 'rm projects/portal/x'" \
  "xargs --max-chars 100 bash -c 'rm projects/portal/x'" \
  "xargs --max-procs 2 bash -c 'rm projects/portal/x'" \
  "xargs --process-slot-var FOO bash -c 'rm projects/portal/x'" \
  "time --format '%R' bash -c 'rm projects/portal/x'" \
  "env -S 'bash -c \"rm projects/portal/x\"'" \
  "env --split-string='bash -c \"rm projects/portal/x\"'" \
  "timeout --kill-after=5 5 bash -c 'rm projects/portal/x'" \
  'projects/portal/bin/env foo' \
  'projects/portal/bin/nohup foo' \
  'projects/portal/bin/time foo' \
  'projects/portal/bin/command foo'; do
  for answer in \
    '{"answers":{"action":{"choice":"require_delegation"},"violation_noul":{"noul":1},"target_domain":{"choice":"project_worker"}}}' \
    '{"answers":{"action":{"choice":"allow_supervisor"},"violation_noul":{"noul":0},"target_domain":{"choice":"supervisor"}}}'; do
    export FM_TEST_JEV_RESPONSE="$answer"
    out=$(cd "$SUPERVISOR" && python3 "$SUPERVISOR/bin/fm-jev-guard.py" --check-only --command "$probe")
    assert_contains "$out" 'Project work must be delegated' "wrapper peel reaches the pre-deny: $probe"
  done
done
# A malformed response or proxy error must fail closed.
export FM_TEST_JEV_RESPONSE='{}'
(cd "$TDIR" && assert_denied 'pytest tests/ -q')
printf '#!/usr/bin/env bash\nexit 1\n' > "$TDIR/proxy"
(cd "$TDIR" && assert_denied 'pytest tests/ -q')

# Both supervisor roles use the policy; disposable worker worktrees remain inert.
touch "$SUPERVISOR/.fm-secondmate-home"
FM_TEST_PRIMARY=0 assert_denied 'cd projects/portal && npm test'
FM_TEST_PRIMARY=0 "$GUARD" --command 'bin/fm-spawn.sh --help' \
  || fail 'secondmate supervisor command denied'
rm "$SUPERVISOR/.fm-secondmate-home"
MOCK_BASE="$TDIR/mock-base"
MOCK_WT="$TDIR/mock-worktree"
fm_git_identity fmtest fmtest@example.invalid
git init -q "$MOCK_BASE"
git -C "$MOCK_BASE" commit -q --allow-empty -m "init base"
git -C "$MOCK_BASE" worktree add -q "$MOCK_WT" -b wt-branch
touch "$MOCK_WT/AGENTS.md"
mkdir -p "$MOCK_WT/bin"
cp "$ROOT/bin/fm-jev-guard.sh" "$ROOT/bin/fm-jev-guard.py" "$MOCK_WT/bin/"
FM_TEST_PRIMARY=0 FM_ROOT_OVERRIDE="$MOCK_WT" "$MOCK_WT/bin/fm-jev-guard.sh" --command 'cd projects/portal && npm test' \
  || fail 'linked worker worktree should remain inert'
transport_payload='{"tool_name":"mcp__chrome_devtools__click","tool_input":{"command":"git status"}}'
rc=0
out=$(printf '%s' "$transport_payload" | FM_TEST_PRIMARY=0 FM_ROOT_OVERRIDE="$MOCK_WT" "$MOCK_WT/bin/fm-jev-guard.sh" 2>"$TDIR/worktree-transport.err") || rc=$?
assert_equals 2 "$rc" 'unlisted transport denies in a linked worktree'
assert_contains "$out" 'has no approved action adapter' 'worktree transport denial is loud'
rc=0
out=$(printf '%s' '{"tool_input":{"command":"git status"}}' | FM_TEST_PRIMARY=0 FM_ROOT_OVERRIDE="$MOCK_WT" "$MOCK_WT/bin/fm-jev-guard.sh" 2>/dev/null) || rc=$?
assert_equals 2 "$rc" 'unnamed transport denies in a linked worktree'
# Classifier-runtime absence denies loudly in supervisor scope; only a payload
# with no extractable command keeps the documented exit 0.
NOJQ="$TDIR/nojqbin"
NOGIT="$TDIR/nogitbin"
mkdir -p "$NOJQ" "$NOGIT"
for tool in bash git python3; do
  ln -s "$(command -v "$tool")" "$NOJQ/$tool"
done
for tool in bash jq python3; do
  ln -s "$(command -v "$tool")" "$NOGIT/$tool"
done
runtime_payload='{"tool_name":"Bash","tool_input":{"command":"cd projects/portal && pytest tests/ -q"}}'
rc=0
printf '%s' "$runtime_payload" | PATH="$NOJQ" "$GUARD" >/dev/null 2>"$TDIR/nojq.err" || rc=$?
assert_equals 2 "$rc" 'missing jq with early utils absent denies'
assert_contains "$(cat "$TDIR/nojq.err")" 'classifier runtime unavailable' 'runtime-absence denial is loud'
rc=0
printf '%s' "$runtime_payload" | PATH="$NOGIT" "$GUARD" >/dev/null 2>"$TDIR/nogit.err" || rc=$?
assert_equals 2 "$rc" 'missing git denies in supervisor scope'
rc=0
printf '%s' "$runtime_payload" | PATH="$NOGIT" FM_TEST_PRIMARY=0 FM_ROOT_OVERRIDE="$MOCK_WT" "$MOCK_WT/bin/fm-jev-guard.sh" >/dev/null 2>"$TDIR/broken-wt.err" || rc=$?
assert_equals 2 "$rc" 'crewmate worktree with broken git fails visibly'
rc=0
printf 'not json' | "$GUARD" >/dev/null 2>&1 || rc=$?
assert_equals 0 "$rc" 'malformed transport is ignored'
rc=0
printf '{"tool_name":"Bash"}' | "$GUARD" >/dev/null 2>&1 || rc=$?
assert_equals 0 "$rc" 'payload without a command is ignored'

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
