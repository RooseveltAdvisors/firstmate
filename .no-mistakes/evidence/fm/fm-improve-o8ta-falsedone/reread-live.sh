#!/usr/bin/env bash
# Live drive of bin/fm-config-push.sh against a disposable lab world on a
# private fm-lab tmux socket (real tmux, real fm-send, real inbox records).
set -u
SRC=${ROOT:?run-worktree}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
# byte-identical export of the target commit, outside the gate repo
mkdir "$LAB/fmroot"; git -C "$SRC" archive HEAD | tar -x -C "$LAB/fmroot"
git -C "$LAB/fmroot" init -q -b main && git -C "$LAB/fmroot" add -A && git -C "$LAB/fmroot" -c user.email=lab@x -c user.name=lab commit -qm "export $(git -C "$SRC" rev-parse --short HEAD)"
ROOT="$LAB/fmroot"
"$ROOT/bin/fm-lab-home.sh" create "$LAB/home" >/dev/null
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
T() { tmux -L fm-lab "$@"; }
cleanup() { chmod -R u+w "$LAB" 2>/dev/null; T kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
touch "$LAB/home/state/.last-watcher-beat"
# secondmate home: a disposable firstmate-shaped home dir (bin/ present)
git init -q -b main "$LAB/sm"; mkdir -p "$LAB/sm/bin"; printf 'echo a\n' > "$LAB/sm/bin/tool.sh" ; printf "v1\n" > "$LAB/sm/AGENTS.md" ; cp "$ROOT/.gitignore" "$LAB/sm/.gitignore"
git -C "$LAB/sm" add -A && git -C "$LAB/sm" -c user.email=lab@x -c user.name=lab commit -qm c1
printf 'sm\n' > "$LAB/sm/.fm-secondmate-home"
mkdir -p "$LAB/sm/config" "$LAB/sm/state"
printf 'window=firstmate:fm-sm\nkind=secondmate\nhome=%s/sm\n' "$LAB" > "$LAB/home/state/sm.meta"
T new-session -d -s firstmate -n keep -x 200 -y 50 bash --norc
T new-window -d -t firstmate -n fm-sm bash --norc
SOCK=$(T display-message -p '#{socket_path}')
export TMUX="$SOCK,0,0"
push() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB/home" FM_SEND_SETTLE=0 bash -c 'cd "$1" && exec ./bin/fm-config-push.sh' _ "$ROOT" 2>&1; echo "exit=$?"; }
pointers() { local n=0 r; for r in "$LAB/home/state/sm.inbox"/*.msg; do [ -e "$r" ] && grep -q CONFIG_REREAD "$r" && n=$((n+1)); done; echo "$n"; }
newest_instr() { local p l=; for p in "$LAB/sm/state"/.fm-inherited-config-reread.*; do case $p in *.pending) continue;; esac; [ -f "$p" ] && l=$p; done; [ -n "$l" ] && sed -n '/BEGIN config\/crew-harness/,/END/p' "$l" | sed -n 2p; }
pending() { ls "$LAB/sm/state"/.fm-inherited-config-reread.*.pending 2>/dev/null | wc -l; }
last_ptr() { local r l=; for r in "$LAB/home/state/sm.inbox"/*.msg; do [ -e "$r" ] && grep -q CONFIG_REREAD "$r" && l=$r; done; [ -n "$l" ] || return; local f; f=$(grep -o "/[^ ]*\.fm-inherited-config-reread\.[^ ]*" "$l" | head -1 | sed "s/[.,;:]*$//"); [ -f "$f" ] && sed -n '/BEGIN config\/crew-harness/,/END/p' "$f" | sed -n 2p; }
show() { echo "  -> last-arrived pointer payload=$(last_ptr)"; echo "  -> inbox CONFIG_REREAD pointers=$(pointers) pending=$(pending) sm-config=$(cat "$LAB/sm/config/crew-harness" 2>/dev/null) newest-delivered-instruction-payload=$(newest_instr)"; }
kill_win() { mkdir -p "$LAB/home/state/sm.inbox"; chmod 500 "$LAB/home/state/sm.inbox"; }
mk_win() { chmod 700 "$LAB/home/state/sm.inbox"; }

echo "== S1 changed config push (A) sends exactly one reread pointer"
printf 'codex\n' > "$LAB/home/config/crew-harness"; push; show
echo "   live pane doorbell:"; T capture-pane -p -t firstmate:fm-sm | grep -v '^$' | tail -3

echo "== S2 re-push with no config change sends nothing"
push; show

echo "== S3 sm-side drift then push of same A: payload byte-identical to latest delivered"
printf 'drifted\n' > "$LAB/sm/config/crew-harness"; push; show

echo "== S4 change to B sends a new pointer"
printf 'pi\n' > "$LAB/home/config/crew-harness"; push; show

echo "== S5 adversarial A->B-pending->revert-A: inbox unwritable while B pushed"
printf 'codex\n' > "$LAB/home/config/crew-harness"; push; show   # A delivered
kill_win
printf 'pi\n' > "$LAB/home/config/crew-harness"; push; show        # B fails -> pending
mk_win
printf 'codex\n' > "$LAB/home/config/crew-harness"; push; show     # revert to A
echo "   expectation: newest delivered instruction payload == sm config == codex"

echo "== S6 adversarial (round finding): A-pending -> B-pending -> revert-A"
printf 'opencode\n' > "$LAB/home/config/crew-harness"; push; show  # baseline delivered
kill_win
printf 'codex\n' > "$LAB/home/config/crew-harness"; push; show     # A pending
printf 'pi\n' > "$LAB/home/config/crew-harness"; push; show        # B pending
mk_win
printf 'codex\n' > "$LAB/home/config/crew-harness"; push; show     # revert to A, drain
echo "   expectation: newest delivered instruction payload == sm config == codex, pending=0"
