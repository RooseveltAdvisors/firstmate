#!/usr/bin/env bash
# Session-start path: fm-bootstrap.sh in a lab home runs the migration and surfaces one summary line, then silence.
set -u
cd "$1"; OWNER=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/wt" "$LAB/proj"
export TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB"; unset TMUX NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
trap 'tmux kill-server 2>/dev/null; rm -rf "$LAB"' EXIT
tmux new-session -d -s firstmate -n fm-live -c "$LAB/wt" claude; sleep 8
printf '%s\n' window=firstmate:fm-live worktree=$LAB/wt project=$LAB/proj kind=scout > "$LAB/state/live.meta"
printf '%s\n' window=firstmate:fm-closed worktree=$LAB/wt project=$LAB/proj kind=scout > "$LAB/state/closed.meta"
chmod 600 "$LAB"/state/*.meta; echo "$OWNER" > "$LAB/state/.lock"
echo "== bootstrap #1 (ENDPOINT_BINDING lines only)"; bin/fm-bootstrap.sh 2>&1 | grep ENDPOINT_BINDING || echo "  (none)"
grep -H -E '^endpoint_' "$LAB"/state/*.meta | sed "s#$LAB#\$LAB#"
echo "== bootstrap #2 (ENDPOINT_BINDING lines only)"; bin/fm-bootstrap.sh 2>&1 | grep ENDPOINT_BINDING || echo "  (none - converged silent)"
