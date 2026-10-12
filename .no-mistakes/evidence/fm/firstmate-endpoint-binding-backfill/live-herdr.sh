#!/usr/bin/env bash
# Herdr branch: a recorded pane that is positively absent on a RUNNING fm-lab-* session is terminal "missing endpoint".
set -u
cd "$1"; OWNER=$2
SESS=$(bin/fm-herdr-lab.sh name epbind); echo "lab session: $SESS"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null; mkdir -p "$LAB/wt" "$LAB/proj"
export FM_HOME="$LAB"; unset TMUX NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
trap 'echo "== teardown"; bin/fm-herdr-lab.sh teardown "$SESS"; echo "  teardown rc=$?"; rm -rf "$LAB"' EXIT
bin/fm-herdr-lab.sh provision "$SESS" || { echo "provision failed"; exit 1; }
echo "== server status"; bin/fm-herdr-lab.sh run "$SESS" workspace list 2>&1 | head -c 300; echo
printf '%s\n' backend=herdr "window=$SESS:p_gone_999" "herdr_session=$SESS" herdr_workspace_id=w_gone herdr_tab_id=t_gone herdr_pane_id=p_gone_999 \
  worktree=$LAB/wt project=$LAB/proj kind=scout > "$LAB/state/hgone.meta"
chmod 600 "$LAB/state/hgone.meta"; echo "$OWNER" > "$LAB/state/.lock"
echo "== migrate run 1"; bin/fm-endpoint-binding-migrate.sh; echo "  rc=$?"
grep -E '^endpoint_' "$LAB/state/hgone.meta" | sed 's/^/  /' || echo "  (no verdict)"
echo "== migrate run 2"; out=$(bin/fm-endpoint-binding-migrate.sh); echo "  rc=$? stdout=[$out]"
