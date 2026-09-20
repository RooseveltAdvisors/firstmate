#!/usr/bin/env bash
# guardrails-demo.sh <firstmate-tree>
#
# The other half of the reclaim contract: an endpoint that merely READS
# `missing` is not licence to re-create anything. Three operator transcripts
# against the real CLI, on the tree under test.
set -u
TREE=$1
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-guardrails.XXXXXX")
cleanup() { rm -rf "$ROOT" /tmp/fm-back1 /tmp/fm-idle1 /tmp/fm-tmux1; }
trap cleanup EXIT
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid
say() { printf '%s\n' "$*"; }
rule() { printf '%s\n' "------------------------------------------------------------"; }

mkgit() {  # <proj> <wt> <branch>
  mkdir -p "$1"; git -C "$1" init -q -b main
  printf '# proj\n' > "$1/README.md"; git -C "$1" add README.md; git -C "$1" commit -qm initial
  git clone --quiet --bare "$1" "$1.origin.git"
  git -C "$1" remote add origin "file://$1.origin.git"
  git -C "$1" worktree add --quiet -b "$3" "$2"
}

herdr_stub() {  # <fakebin>
  cat > "$1/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/herdr-log"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  if [ -f "$D/herdr-stopped" ]; then
    printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":false}}\n'
  else
    printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n'
  fi
  exit 0
fi
if [ "${1:-}" = server ]; then rm -f "$D/herdr-stopped"; exit 0; fi
if [ -f "$D/herdr-stopped" ]; then echo 'error: could not connect to the herdr server' >&2; exit 1; fi
case "${1:-} ${2:-}" in
  'pane get')
    if [ "${3:-}" = "$(cat "$D/herdr-pane")" ]; then
      printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' "${3:-}" "$(cat "$D/cwd")"
    else printf '{"error":{"code":"pane_not_found"}}\n'; fi; exit 0 ;;
  'agent get')
    if [ -f "$D/herdr-agent-live" ]; then printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else printf '{"error":{"code":"agent_not_found"}}\n'; fi; exit 0 ;;
  'pane process-info')
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"claude","argv":["claude"],"cmdline":"claude"}]}}}\n' "$(cat "$D/herdr-pane")"; exit 0 ;;
  'pane send-text')
    # A launch arrives as a short line sourcing the STAGED launch file rather
    # than the literal command, so read that file back before deciding what was
    # delivered - same shape tests/fm-control-relaunch.test.sh's fixture uses.
    payload=${4:-}
    case "$payload" in ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;; esac
    case "$payload" in *'encode launch-brief'*) : > "$D/herdr-agent-live" ;; esac; exit 0 ;;
  'workspace list') printf '{"result":{"workspaces":[]}}\n'; exit 0 ;;
  'workspace create') printf '{"result":{"workspace":{"workspace_id":"wsnew"},"tab":{"tab_id":"seedtab"}}}\n'; exit 0 ;;
  'tab list') printf '{"result":{"tabs":[]}}\n'; exit 0 ;;
  'tab create')
    printf '%s\n' "$*" >> "$D/herdr-created-tabs"
    printf '{"result":{"tab":{"tab_id":"tabnew"},"root_pane":{"pane_id":"%%9"}}}\n'
    printf '%s' '%9' > "$D/herdr-pane"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/herdr"
}

tmux_stub() {  # <fakebin>
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift; literal=0
    while [ $# -gt 0 ]; do case "$1" in -t) shift 2 ;; -l) literal=1; shift ;; *) break ;; esac; done
    payload=${1:-}
    if [ "$literal" = 1 ]; then printf '%s\n' "$payload" >> "$D/literal"
    else printf '%s\n' "$payload" >> "$D/keys"; fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in
      *cursor_y*) printf '1\n'; exit 0 ;;
      *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
      *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
    esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf 'x\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
  new-window)
    shift; name=
    while [ $# -gt 0 ]; do case "$1" in -n) name=${2:-}; shift 2 ;; -c|-t) shift 2 ;; *) shift ;; esac; done
    printf '%s\n' "$name" >> "$D/windows"; printf '%s\n' "$name" >> "$D/created-windows"
    printf '@9\n'; exit 0 ;;
  new-session)
    shift; printf 'session\n' >> "$D/created-sessions"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/tmux"
  cat > "$1/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$1/sleep"
}

# case_dir <name> <id> <backend> -> builds a ship task; echoes nothing
CASE=
new_task() {  # <name> <id> <backend> [session]
  local name=$1 id=$2 backend=$3 ses=${4:-fmlab}
  CASE=$ROOT/$name
  mkdir -p "$CASE/home/state" "$CASE/home/data/$id" "$CASE/fake" "$CASE/fakebin" "$CASE/user-home"
  mkgit "$CASE/proj" "$CASE/wt" "task-$id"
  printf 'unfinished work\n' > "$CASE/wt/scratch.txt"
  cat > "$CASE/home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the reclaim guardrails for $id.

## Firstmate spec
Keep one agent per worktree.
EOF
  printf '%s' "$CASE/wt" > "$CASE/fake/cwd"
  : > "$CASE/fake/herdr-log"
  {
    echo "endpoint_task_id=$id"; echo "worktree=$CASE/wt"; echo "project=$CASE/proj"
    echo "harness=claude"; echo "kind=ship"; echo "mode=no-mistakes"; echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"; echo "model=default"; echo "effort=default"
  } > "$CASE/home/state/$id.meta"
  if [ "$backend" = herdr ]; then
    {
      echo "window=$ses:%7"; echo "backend=herdr"; echo "herdr_session=$ses"
      echo "herdr_workspace_id=ws1"; echo "herdr_tab_id=tab1"; echo "herdr_pane_id=%7"
    } >> "$CASE/home/state/$id.meta"
    herdr_stub "$CASE/fakebin"
  else
    printf '%s\n' "window=fmses:fm-$id" >> "$CASE/home/state/$id.meta"
    printf 'claude' > "$CASE/fake/command"
    : > "$CASE/fake/windows"      # the window is absent from a readable inventory
    tmux_stub "$CASE/fakebin"
  fi
}

fm() {
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$CASE/fakebin:$PATH" FM_HOME="$CASE/home" FM_FAKE_DIR="$CASE/fake" \
    HOME="$CASE/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_GATE_REFUSE_BYPASS=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$@" 2>&1
}
meta() { grep "^$2=" "$CASE/home/state/$1.meta" | tail -1 | cut -d= -f2-; }
show() { printf '$ %s\n' "$2"; printf '%s\n' "$1"; }

say "================================================================"
say "  reclaim guardrails - three operator transcripts"
say "  (tree under test: $TREE)"
say "================================================================"

# --- 1. herdr: the server was merely stopped; the pane survived it ----------
new_task stopped idle1 herdr
: > "$CASE/fake/herdr-stopped"        # server down -> first read says `missing`
printf '%s' '%7' > "$CASE/fake/herdr-pane"   # ...but the recorded pane is still there
say "CASE 1 - herdr session server was STOPPED; the recorded pane survives a restart."
say "         The state read says 'missing'; the pane was never destroyed."
rule
out=$(fm "$TREE/bin/fm-control.sh" idle1 exit); rc=$?
show "$out" "bin/fm-control.sh idle1 exit"; say "[exit status $rc]"
out=$(fm "$TREE/bin/fm-control.sh" idle1 relaunch --note "server bounced; carry on"); rc=$?
show "$out" 'bin/fm-control.sh idle1 relaunch --note "server bounced; carry on"'; say "[exit status $rc]"
say "  endpoint after : $(meta idle1 window)  (unchanged - the pane was ADOPTED)"
say "  tabs created   : $([ -s "$CASE/fake/herdr-created-tabs" ] && cat "$CASE/fake/herdr-created-tabs" || echo 'none - no second tab beside the surviving pane')"
say "  side effect    : $(grep -q '^server --session fmlab$' "$CASE/fake/herdr-log" && echo 'exit ran `herdr server --session fmlab` to ask - it is not a read-only inspection (documented)' || echo 'none')"
rule

# --- 2. herdr: the agent came back with its server --------------------------
new_task back back1 herdr
: > "$CASE/fake/herdr-stopped"
printf '%s' '%7' > "$CASE/fake/herdr-pane"
: > "$CASE/fake/herdr-agent-live"     # the agent returns with the server
say "CASE 2 - the herdr server comes back and so does the AGENT."
say "         Re-creating an endpoint here would put two agents on one worktree."
rule
out=$(fm "$TREE/bin/fm-spawn.sh" back1 --relaunch --harness claude); rc=$?
show "$out" "bin/fm-spawn.sh back1 --relaunch --harness claude"; say "[exit status $rc]"
say "  endpoint after : $(meta back1 window)  (record untouched)"
say "  tabs created   : $([ -s "$CASE/fake/herdr-created-tabs" ] && cat "$CASE/fake/herdr-created-tabs" || echo 'none')"
rule

# --- 3. tmux: absence cannot be proven from a task record -------------------
new_task tmux tmux1 tmux
say "CASE 3 - a TMUX task whose window is absent from a readable inventory."
say "         A task record carries no socket identity, so 'gone' and 'on a"
say "         server this seat cannot address' are indistinguishable."
rule
before=$(cat "$CASE/home/data/tmux1/brief.md")
out=$(fm "$TREE/bin/fm-control.sh" tmux1 exit); rc=$?
show "$out" "bin/fm-control.sh tmux1 exit"; say "[exit status $rc]"
out=$(fm "$TREE/bin/fm-control.sh" tmux1 relaunch --note "this note must never reach a live agent"); rc=$?
show "$out" 'bin/fm-control.sh tmux1 relaunch --note "this note must never reach a live agent"'; say "[exit status $rc]"
say "  windows created: $([ -s "$CASE/fake/created-windows" ] && cat "$CASE/fake/created-windows" || echo 'none')"
say "  bytes sent into any pane: $([ -s "$CASE/fake/literal" ] && cat "$CASE/fake/literal" || echo 'none')"
say "  instructions   : $([ "$(cat "$CASE/home/data/tmux1/brief.md")" = "$before" ] && echo 'byte-identical - the progress note was rolled back' || echo 'CHANGED')"
rule
