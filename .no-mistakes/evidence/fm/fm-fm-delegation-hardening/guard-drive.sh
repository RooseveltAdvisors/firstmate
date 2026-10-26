#!/usr/bin/env bash
# Live drive of the real bin/fm-jev-guard.sh delegation guard in a disposable lab home.
set -u

REPO=/home/jon/.no-mistakes/worktrees/46339c0817e0/01M5SDV9REPXRKVD9443H5KZTR
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
trap 'rm -rf "$LAB"' EXIT

"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab home create failed"; exit 1; }
mkdir -p "$LAB/bin" "$LAB/projects/portal"
touch "$LAB/AGENTS.md"
cp "$REPO/bin/fm-jev-guard.sh" "$REPO/bin/fm-jev-guard.py" "$LAB/bin/"

# The lab home is a real primary checkout shape: git-dir == git-common-dir.
git -C "$LAB" init -q 2>/dev/null
git -C "$LAB" -c user.email=lab@invalid -c user.name=lab commit -q --allow-empty -m init 2>/dev/null

# Counting Jev stub: records one tick per query and answers per FM_TEST_JEV_RESPONSE.
cat > "$LAB/proxy" <<'PROXY'
#!/usr/bin/env bash
[ -n "${FM_TEST_QUERY_LOG:-}" ] && echo tick >> "$FM_TEST_QUERY_LOG"
printf '%s' "${FM_TEST_JEV_RESPONSE:-}"
PROXY
chmod +x "$LAB/proxy"
cat > "$LAB/proxy-broken" <<'PROXY'
#!/usr/bin/env bash
exit 1
PROXY
chmod +x "$LAB/proxy-broken"

GUARD="$LAB/bin/fm-jev-guard.sh"
PASS=0
FAIL=0

export FM_ROOT_OVERRIDE="$LAB" FM_HOME="$LAB"
export FM_JEV_PROXY_BIN="$LAB/proxy"
export FM_TEST_JEV_RESPONSE='{"answers":{"action":{"choice":"allow_supervisor"},"violation_noul":{"noul":0},"target_domain":{"choice":"supervisor"}}}'
unset FM_TEST_PRIMARY 2>/dev/null || true

run_case() { # <allow|deny> <query-delta|-> <fragment-or-> <command>  [CASE_CWD]
  local want=$1 qd=$2 frag=$3 cmd=$4 out rc=0 q0 q1 ok=1 why=""
  : > "$LAB/qlog"
  q0=$(wc -l < "$LAB/qlog" | tr -d ' ')
  out=$(cd "${CASE_CWD:-$PWD}" && FM_TEST_QUERY_LOG="$LAB/qlog" "$GUARD" --command "$cmd" 2>&1) || rc=$?
  q1=$(wc -l < "$LAB/qlog" | tr -d ' ')
  case "$want" in
    allow) [ "$rc" -eq 0 ] || { ok=0; why="expected allow (exit 0), got exit $rc"; } ;;
    deny)  [ "$rc" -eq 2 ] || { ok=0; why="expected deny (exit 2), got exit $rc"; } ;;
  esac
  if [ "$ok" -eq 1 ] && [ "$frag" != "-" ]; then
    case "$out" in
      *"$frag"*) ;;
      *) ok=0; why="missing fragment '$frag'"; ;;
    esac
  fi
  if [ "$ok" -eq 1 ] && [ "$qd" != "-" ] && [ "$((q1 - q0))" -ne "$qd" ]; then
    ok=0; why="expected $qd Jev queries, saw $((q1 - q0))"
  fi
  if [ "$ok" -eq 1 ]; then
    PASS=$((PASS + 1))
    printf 'PASS | %s | queries=%s | %s\n' "$want" "$((q1 - q0))" "$cmd"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL | %s | queries=%s | %s | %s | out=%s\n' "$want" "$((q1 - q0))" "$cmd" "$why" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-220)"
  fi
}

echo "=== S1: supervisor reads fast-pass with zero Jev queries (allow, 0 queries) ==="
for cmd in \
  'bin/fm-wake-drain.sh' \
  'bd show x' \
  'herdr --session firstmate agent read w1:p1' \
  'gh pr view 7' \
  'gh pr diff 7' \
  'gh pr status' \
  'git status --short' \
  'git log --oneline -5' \
  'git -C projects/portal status --short' \
  'bin/fm-send.sh --help' \
  'bin/fm-spawn.sh --help' \
  'tasks-axi list' \
  "bash -ec 'bd show x'" \
  "zsh -c 'bd show x'" \
  'bd show x 2>&1' \
  'bd list > /dev/null' \
  "bin/fm-send.sh worker 'cd projects/portal && npm test; systemctl restart app'" ; do
  run_case allow 0 - "$cmd"
done

echo "=== S2: project work is refused as delegation BEFORE any Jev query (deny, 0 queries) ==="
for cmd in \
  'cd projects/portal && npm test' \
  'git -C projects/portal commit -m x' \
  'cd /opt/ra/firstmate/projects/portal && pytest tests/ -q' \
  "bash -c 'cd projects/portal && npm test'" \
  "nohup bash -c 'rm projects/portal/x'" \
  "timeout 5 bash -c 'cd projects/portal && npm test'" \
  'xargs -a projects/portal/data echo hi' \
  'time -o projects/portal/out.log ls' \
  "BASH_ENV=projects/portal/evil.sh bash -c 'bd show x'" \
  "bash --init-file projects/portal/evil.sh -i -c 'bd show x'" \
  'projects/portal/fm-deploy.sh' \
  "bash -c 'cat > projects/portal/new.py'" \
  'echo x > projects/portal/app.py' \
  "env -S 'bash -c \"rm projects/portal/x\"'" \
  'find . -path "./projects/*" -delete' \
  'awk -f projects/portal/rules.awk state/task.status' \
  "ksh -c 'rm projects/portal/x'" \
  'bin/fm-send.sh --help; cd projects/portal && npm test' \
  'projects/portal/bash bin/fm-send.sh --help' \
  "find . -exec bash -c 'rm projects/portal/x' {} +" ; do
  run_case deny 0 'Project work must be delegated' "$cmd"
done
echo "--- project cwd itself is project work ---"
CASE_CWD="$LAB/projects/portal" run_case deny 0 'Project work must be delegated' 'pytest tests/ -q'
echo "--- treehouse worktree cwd is project work ---"
mkdir -p "$LAB/.treehouse/pool/1/project"
CASE_CWD="$LAB/.treehouse/pool/1/project" run_case deny 0 'Project work must be delegated' 'bun test'

echo "=== S3: non-fast-path commands are CLASSIFIED (query) not fast-passed; Jev's verdict decides ==="
for cmd in 'gh pr merge 7' 'systemctl restart app' 'cat state/task.status' 'D=projects/portal; rm $D/x' 'git log &> /tmp/out' 'bd list > /tmp/out' 'git show x >| /tmp/out' 'bd list > /dev/fd/9'; do
  run_case allow 1 - "$cmd"
done
export FM_TEST_JEV_RESPONSE='{"answers":{"action":{"choice":"require_delegation"},"violation_noul":{"noul":0.9},"target_domain":{"choice":"project_worker"}}}'
run_case deny 1 'require_delegation' 'gh pr merge 7'
run_case deny 1 'require_delegation' 'systemctl restart app'
run_case deny 1 'require_delegation' 'git log &> /tmp/out'
export FM_TEST_JEV_RESPONSE='{"answers":{"action":{"choice":"allow_supervisor"},"violation_noul":{"noul":0},"target_domain":{"choice":"supervisor"}}}'

echo "=== S4: allowed decisions are never cached (two identical probes = two queries) ==="
: > "$LAB/qlog"
FM_TEST_QUERY_LOG="$LAB/qlog" "$GUARD" --command 'cat state/task.status' >/dev/null 2>&1
FM_TEST_QUERY_LOG="$LAB/qlog" "$GUARD" --command 'cat state/task.status' >/dev/null 2>&1
if [ "$(wc -l < "$LAB/qlog" | tr -d ' ')" = 2 ]; then
  PASS=$((PASS + 1)); echo "PASS | uncached | queries=2 | repeated 'cat state/task.status'"
else
  FAIL=$((FAIL + 1)); echo "FAIL | uncached | repeated probe cached a decision"
fi

echo "=== S5: Jev outage / broken / malformed answers FAIL CLOSED for non-allowlist commands ==="
export FM_JEV_PROXY_BIN="$LAB/does-not-exist"
run_case deny 0 'Jev unavailable' 'python3 -c "print(1)"'
run_case deny 0 'Jev unavailable' 'git log &> /tmp/out'
export FM_JEV_PROXY_BIN="$LAB/proxy-broken"
run_case deny - 'require_delegation' 'python3 -c "print(1)"'
export FM_JEV_PROXY_BIN="$LAB/proxy"
export FM_TEST_JEV_RESPONSE='{}'
run_case deny - 'require_delegation' 'python3 -c "print(1)"'
export FM_TEST_JEV_RESPONSE='{"answers":{"action":{"choice":"allow_supervisor"},"violation_noul":{"noul":0},"target_domain":{"choice":"supervisor"}}}'
echo "--- outage still allows the supervisor allowlist and still pre-denies project work ---"
export FM_JEV_PROXY_BIN="$LAB/does-not-exist"
run_case allow 0 - 'bd show x'
run_case deny 0 'Project work must be delegated' 'cd projects/portal && npm test'
export FM_JEV_PROXY_BIN="$LAB/proxy"

echo "=== S6: PreToolUse transports: only governed shell/read tools are admitted ==="
t_payload() { # <json> <expect:allow|deny> <fragment-or->
  local json=$1 want=$2 frag=$3 out rc=0
  out=$(printf '%s' "$json" | "$GUARD" 2>&1) || rc=$?
  if { [ "$want" = allow ] && [ "$rc" -eq 0 ]; } || { [ "$want" = deny ] && [ "$rc" -eq 2 ]; } \
     && { [ "$frag" = "-" ] || [[ "$out" == *"$frag"* ]]; }; then
    PASS=$((PASS + 1)); printf 'PASS | transport %s | rc=%s | %s\n' "$want" "$rc" "$(printf '%s' "$json" | cut -c1-90)"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL | transport %s | rc=%s | %s | out=%s\n' "$want" "$rc" "$(printf '%s' "$json" | cut -c1-90)" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
  fi
}
t_payload '{"tool_name":"Bash","tool_input":{"command":"bd show x"}}' allow -
t_payload '{"tool_name":"Shell","tool_input":{"command":"git status"}}' allow -
t_payload '{"tool_name":"Read","tool_input":{"command":"state/task.status"}}' allow -
t_payload '{"tool_name":"run_terminal_command","tool_input":{"command":"bd show x"}}' allow -
t_payload '{"tool_name":"Bash","tool_input":{"command":"cd projects/portal && npm test"}}' deny 'Project work must be delegated'
t_payload '{"tool_name":"mcp__chrome_devtools__click","tool_input":{"command":"git status"}}' deny 'has no approved action adapter'
t_payload '{"tool_name":"browser","tool_input":{"command":"git status"}}' deny 'has no approved action adapter'
t_payload '{"tool_input":{"command":"git status"}}' deny 'has no approved action adapter'
t_payload 'not json at all' allow -

echo "=== S7: scope: secondmate home governed, linked worker worktree inert ==="
touch "$LAB/.fm-secondmate-home"
out=$(FM_TEST_PRIMARY=0 "$GUARD" --command 'cd projects/portal && npm test' 2>&1); rc=$?
if [ "$rc" -eq 2 ] && [[ "$out" == *'Project work must be delegated'* ]]; then
  PASS=$((PASS + 1)); echo "PASS | secondmate home governed | project work denied"
else
  FAIL=$((FAIL + 1)); echo "FAIL | secondmate home governed | rc=$rc out=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
fi
out=$(FM_TEST_PRIMARY=0 "$GUARD" --command 'bin/fm-spawn.sh --help' 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  PASS=$((PASS + 1)); echo "PASS | secondmate home supervisory command allowed"
else
  FAIL=$((FAIL + 1)); echo "FAIL | secondmate home supervisory command denied rc=$rc"
fi
rm "$LAB/.fm-secondmate-home"

BASE="$LAB/mock-base"; WT="$LAB/mock-worktree"
git init -q "$BASE"
git -C "$BASE" -c user.email=lab@invalid -c user.name=lab commit -q --allow-empty -m init
git -C "$BASE" worktree add -q "$WT" -b wt-branch
touch "$WT/AGENTS.md"; mkdir -p "$WT/bin"
cp "$REPO/bin/fm-jev-guard.sh" "$REPO/bin/fm-jev-guard.py" "$WT/bin/"
out=$(FM_TEST_PRIMARY=0 FM_ROOT_OVERRIDE="$WT" FM_HOME="$WT" "$WT/bin/fm-jev-guard.sh" --command 'cd projects/portal && npm test' 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  PASS=$((PASS + 1)); echo "PASS | linked worker worktree inert | project command exit 0"
else
  FAIL=$((FAIL + 1)); echo "FAIL | linked worker worktree inert | rc=$rc out=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
fi
out=$(printf '%s' '{"tool_name":"mcp__chrome_devtools__click","tool_input":{"command":"git status"}}' | FM_TEST_PRIMARY=0 FM_ROOT_OVERRIDE="$WT" FM_HOME="$WT" "$WT/bin/fm-jev-guard.sh" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && [[ "$out" == *'has no approved action adapter'* ]]; then
  PASS=$((PASS + 1)); echo "PASS | unlisted transport still refused inside inert worktree"
else
  FAIL=$((FAIL + 1)); echo "FAIL | unlisted transport in worktree | rc=$rc"
fi

echo
echo "GUARD-LIVE RESULT: pass=$PASS fail=$FAIL"
echo "telemetry tail (written by the real product into the lab state):"
tail -n 25 "$LAB/state/.jev-guard-telemetry" 2>/dev/null | cut -c1-150
exit 0
