#!/usr/bin/env bash
# Live: real Herdr (named fm-lab-* session via bin/fm-herdr-lab.sh), real
# fm-spawn.sh --backend herdr, a disposable FM_HOME, and a treehouse shim that
# prints the pool-full refusal inside the real pane.
set -u
ROOT=$1
LABHELP="$ROOT/bin/fm-herdr-lab.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-capl.XXXXXX")
home="$W/home"; proj="$W/project"; fb="$W/fakebin"
mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$fb" "$W/userhome"
printf 'codex\n' > "$home/config/crew-harness"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
tasks-axi add cap-x1 "capacity live task" --kind ship --file "$home/data/backlog.md" >/dev/null
mkdir -p "$home/data/cap-x1"
printf '# Task\n## Captain'"'"'s intent\nLive pool-full hold.\n\n## Firstmate spec\nVerdict from the backend read.\n' > "$home/data/cap-x1/brief.md"
git init -q "$proj" && git -C "$proj" commit -q --allow-empty -m init
cat > "$fb/treehouse" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  get) printf 'all 3 worktrees are in use or dirty (max_trees = 4). Run %streehouse status%s to see details, or increase max_trees in treehouse.toml\n' "'" "'"; exit 1 ;;
  status) printf '%s\n' '[{"name":"7","path":"$W/pool/7/project","status":"in-use","flavor":"git","lease_id":"","lease_holder":"","leased_at":null,"processes":[]}]' ;;
esac
EOF
chmod +x "$fb/treehouse"
printf '#!/bin/bash\nexport PATH="%s:$PATH"\nexec /bin/bash --noprofile --norc -i "$@"\n' "$fb" > "$fb/labshell"; chmod +x "$fb/labshell"
export PATH="$fb:$PATH" SHELL="$fb/labshell" TREEHOUSE_ROOT="$W/pool"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
S=$("$LABHELP" name capfull) || exit 9
echo "lab session: $S"
"$LABHELP" provision "$S" || { echo "lab provision failed"; rm -rf "$W"; exit 9; }
export HERDR_SESSION="$S"
echo "--- panes before spawn"; "$LABHELP" run "$S" pane list | jq -c '[.result.panes[]?.pane_id]'
echo "\$ fm-spawn.sh cap-x1 <project> --backend herdr --mode no-mistakes --yolo off"
env -u NO_MISTAKES_GATE FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$W/userhome" CLAUDE_CONFIG_DIR='' \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
  FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 \
  timeout 180 "$ROOT/bin/fm-spawn.sh" cap-x1 "$proj" --backend herdr --mode no-mistakes --yolo off
echo "spawn exit=$?"
echo "--- panes after spawn"; "$LABHELP" run "$S" pane list | jq -c '[.result.panes[]? | {pane_id, cwd: .foreground_cwd}]'
echo "--- state files"; ls "$home/state"
echo "--- backlog item"; (cd "$home" && tasks-axi show cap-x1 --file "$home/data/backlog.md" 2>/dev/null || tasks-axi show cap-x1) | grep -E "state:|held:|hold" 
"$LABHELP" teardown "$S"; echo "teardown exit=$?"
chmod -R u+w "$W"; rm -rf "$W"
