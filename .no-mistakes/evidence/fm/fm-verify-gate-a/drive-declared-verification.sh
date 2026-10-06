#!/usr/bin/env bash
# Live drive: real bin/fm-crew-state.sh over a disposable lab FM_HOME,
# a real git worktree, a real lab tmux socket, and a real python http server.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
unset TMUX NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$LAB"
cleanup() { [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null; tmux -L fm-lab kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
WT="$LAB/wt"
git init -q -b fm/declared "$WT"
git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'the fix, properly pushed'
git -C "$WT" update-ref refs/remotes/origin/fm/declared "$(git -C "$WT" rev-parse HEAD)"
tmux -L fm-lab new-session -d -s fm -n fm-declared "sleep 600"
export TMUX="$(tmux -L fm-lab display-message -p "#{socket_path}"),0,0"
echo "## lab tmux socket: $TMUX"
. "$ROOT/bin/fm-meta-lib.sh" 2>/dev/null || true
cat > "$LAB/state/declared.meta" <<M
window=fm:fm-declared
worktree=$WT
project=$WT
kind=ship
mode=no-mistakes
harness=claude
M
printf 'done: PR https://example.test/o/r/pull/9 checks green\n' > "$LAB/state/declared.status"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" declared)
"$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" declared idle --gen "$gen" --source claude-hook --event stop
mkdir -p "$LAB/site"; printf 'the live fix is deployed\n' > "$LAB/site/index.html"
python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$LAB/site" > "$LAB/serve.log" 2>&1 &
PID=$!
for i in $(seq 1 40); do port=$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$LAB/serve.log" | head -1); [ -n "$port" ] && break; sleep 0.25; done
printf 'http: http://127.0.0.1:%s/ 200 the live fix is deployed\n' "$port" > "$LAB/state/declared.verify"
chmod 600 "$LAB/state/declared.verify"
echo "## declaration: $(cat "$LAB/state/declared.verify")"
echo "## 1. site UP (good done:)"; "$ROOT/bin/fm-crew-state.sh" declared; echo "exit=$?"
printf 'something else\n' > "$LAB/site/index.html"
echo "## 2. site UP but serving wrong content (bad done:)"; "$ROOT/bin/fm-crew-state.sh" declared; echo "exit=$?"
printf 'the live fix is deployed\n' > "$LAB/site/index.html"
kill "$PID"; wait "$PID" 2>/dev/null; PID=
echo "## 3. site DOWN, same task/commit/done:/declaration (bad done:)"; "$ROOT/bin/fm-crew-state.sh" declared; echo "exit=$?"
echo "## 4. declaration removed (no declaration gates nothing)"; rm "$LAB/state/declared.verify"; "$ROOT/bin/fm-crew-state.sh" declared; echo "exit=$?"
printf 'run: test 1 = 2\n' > "$LAB/state/declared.verify"; chmod 600 "$LAB/state/declared.verify"
echo "## 5. failing run: declaration"; "$ROOT/bin/fm-crew-state.sh" declared; echo "exit=$?"
printf 'run: test 1 = 1\nfile: %s/site/index.html the live fix is deployed\n' "$LAB" > "$LAB/state/declared.verify"; chmod 600 "$LAB/state/declared.verify"
echo "## 6. passing run: + file: declaration"; "$ROOT/bin/fm-crew-state.sh" declared; echo "exit=$?"
chmod 644 "$LAB/state/declared.verify"
echo "## 7. world-readable (untrusted) declaration"; "$ROOT/bin/fm-crew-state.sh" declared; echo "exit=$?"
printf 'bogus: whatever\n' > "$LAB/state/declared.verify"; chmod 600 "$LAB/state/declared.verify"
echo "## 8. unknown check verb"; "$ROOT/bin/fm-crew-state.sh" declared; echo "exit=$?"
printf 'run: test 1 = 2\n' > "$LAB/state/declared.verify"; chmod 600 "$LAB/state/declared.verify"
echo "## 9. FM_VERIFY_PASS_TIMEOUT=9 above the cap"; FM_VERIFY_PASS_TIMEOUT=9 "$ROOT/bin/fm-crew-state.sh" declared; echo "exit=$?"
