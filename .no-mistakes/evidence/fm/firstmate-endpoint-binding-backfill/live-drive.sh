#!/usr/bin/env bash
# Live drive of fm-endpoint-binding-migrate.sh: disposable lab home + private real tmux server.
set -u
WT=$1; OWNER=$2
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/wt-good" "$LAB/wt-shell" "$LAB/wt-late" "$LAB/proj"
export TMUX_TMPDIR="$LAB/tmux"; unset TMUX NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$LAB"
S="$LAB/state"
trap 'tmux kill-server 2>/dev/null; rm -rf "$LAB"' EXIT
meta() { f=$S/$1.meta; shift; printf '%s\n' "$@" > "$f"; chmod 600 "$f"; }
dump() { for f in "$S"/*.meta; do printf '  %-10s %s\n' "$(basename "$f")" "$(grep -E '^(endpoint_task_id|endpoint_binding_verdict)=' "$f" | tr '\n' ' ')"; done; }
# real tmux session "firstmate": a real claude agent window, an idle shell window
tmux new-session -d -s firstmate -n fm-good -c "$LAB/wt-good" claude
tmux new-window -d -t firstmate -n fm-shell -c "$LAB/wt-shell"
tmux new-window -d -t firstmate -n fm-late -c "$LAB/wt-late" claude
sleep 8
echo "== live tmux inventory (private socket)"; tmux list-windows -t firstmate -F '  #{window_name} cmd=#{pane_current_command} cwd=#{pane_current_path}'
meta good   window=firstmate:fm-good  worktree=$LAB/wt-good  project=$LAB/proj kind=scout
meta shell  window=firstmate:fm-shell worktree=$LAB/wt-shell project=$LAB/proj kind=scout
meta gone   window=firstmate:fm-gone  worktree=$LAB/wt-good  project=$LAB/proj kind=scout
meta bad    window=firstmate:notfm    worktree=$LAB/wt-good  project=$LAB/proj kind=scout
meta bound  window=firstmate:fm-bound endpoint_task_id=bound worktree=$LAB/wt-good project=$LAB/proj kind=scout
meta orc    backend=orca window=firstmate:fm-orc worktree=$LAB/wt-good project=$LAB/proj kind=scout
# 20 closed-task records sorting before a live one (budget adversarial)
for i in $(seq -w 1 20); do meta a$i window=firstmate:fm-a$i worktree=$LAB/wt-late project=$LAB/proj kind=scout; done
meta late   window=firstmate:fm-late  worktree=$LAB/wt-late  project=$LAB/proj kind=scout
meta mism   window=firstmate:fm-mism  worktree=$LAB/proj project=$LAB/proj kind=scout
tmux new-window -d -t firstmate -n fm-mism -c "$LAB/wt-good" claude; sleep 6
echo "== run 0: lock NOT owned by this session"
echo 999999 > "$S/.lock"; bin/fm-endpoint-binding-migrate.sh; echo "  rc=$?"
echo "$OWNER" > "$S/.lock"
echo "== run 1 (lock owned by live claude harness pid $OWNER)"
bin/fm-endpoint-binding-migrate.sh; echo "  rc=$?"
dump
echo "== orc record unchanged?"; cat "$S/orc.meta" | sed 's/^/  /'
echo "== run 2 (converge)"; out=$(bin/fm-endpoint-binding-migrate.sh); echo "  rc=$? stdout=[$out]"
echo "== stray candidates:"; ls -A "$S" | grep candidate || echo "  none"
