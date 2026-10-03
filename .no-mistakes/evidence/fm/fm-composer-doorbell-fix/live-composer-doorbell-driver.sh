#!/usr/bin/env bash
# Live driver: real Claude Code worker in a private tmux server + lab FM_HOME,
# steered through the real bin/fm-send.sh while its composer holds stale text.
set -u
ROOT=${ROOT:?}
EV=${EV:?}
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
SOCKET="fm-lab-cd-$$"
REAL_TMUX=$(command -v tmux)
mkdir -p "$LAB/shim"
# tmux shim: pins every bare tmux call to the private socket; when $LAB/fault
# exists it refuses bare named keys (Enter / C-u) the way a backend refusing the
# key (invalid_key class) does - the real product path, with an injected refusal.
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
if [ -e "$LAB/fault" ] && [ "\$1" = send-keys ] && [ \$# -eq 4 ] && { [ "\$4" = Enter ] || [ "\$4" = C-u ]; }; then
  echo "tmux: invalid_key (injected refusal)" >&2; exit 1
fi
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
export PATH="$LAB/shim:$PATH"
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
. "$ROOT/bin/fm-tmux-lib.sh"
. "$ROOT/bin/fm-backend.sh"; fm_backend_source tmux
tmux new-session -d -s lab -x 200 -y 50 -c "$ROOT"
LOG="$EV/live-composer-doorbell-transcript.txt"; : > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
snap() { say "----- pane ($1) -----"; tmux capture-pane -p -t "lab:$2" | grep '[^[:space:]]' | tail -${3:-14} | tee -a "$LOG" >/dev/null; say "---------------------"; }

launch() { # <win> <task>
  tmux new-window -d -t lab: -n "$1" -c "$ROOT" -- bash -lc "export FM_TASK_INBOX=$(printf '%q' "$LAB/state/$2.inbox"); CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'"
  printf 'window=lab:%s\nkind=ship\nharness=claude\n' "$1" > "$LAB/state/$2.meta"
  local i=0; while [ $i -lt 60 ]; do [ "$(fm_tmux_composer_state "lab:$1")" = empty ] && return 0; sleep 1; i=$((i+1)); done
  say "WARN: $1 never classified empty"; return 0
}
send() { # <task> <msg> ; sets RC
  RC=0; FM_HOME="$LAB" "$ROOT/bin/fm-send.sh" "$1" "$2" >"$LAB/out" 2>"$LAB/err" || RC=$?
  say "\$ fm-send.sh $1 '<steer>'  -> exit $RC"; sed 's/^/  stderr: /' "$LAB/err" | tee -a "$LOG" >/dev/null
}
waitfile() { local i=0; while [ $i -lt ${2:-180} ]; do [ -e "$1" ] && return 0; sleep 1; i=$((i+1)); done; return 1; }

say "=== claude $(claude --version | head -1); lab FM_HOME=$LAB ==="

if [ "${SCEN:-all}" = all ]; then
# S1: word-bearing stale text held -> submitted as part of the send, doorbell rings, worker acts+acks
say; say "=== S1: stale word text held in an idle composer ==="
launch w1 t1
tmux send-keys -t lab:w1 -l "stale note from earlier: reply OK-STALE"
sleep 1; say "composer verdict before send: $(fm_tmux_composer_state lab:w1)"; snap "S1 before send" w1 6
send t1 "Firstmate live check: run exactly this shell command now: touch $LAB/acted-t1 - then follow the mv instruction you were given for this message. Reply with one short line."
if waitfile "$LAB/acted-t1" 240 && waitfile "$LAB/state/t1.inbox/handled/001.msg" 60; then say "S1 RESULT: PASS (exit $RC; worker acted and acked; held text submitted)"; else say "S1 RESULT: FAIL (acted=$([ -e "$LAB/acted-t1" ]&&echo y||echo n) acked=$([ -e "$LAB/state/t1.inbox/handled/001.msg" ]&&echo y||echo n))"; fi
snap "S1 after" w1 30

# S2: contentless junk held -> dropped with Ctrl-U, doorbell rings
say; say "=== S2: punctuation-only junk held in an idle composer ==="
launch w2 t2
tmux send-keys -t lab:w2 -l ';;;...---'
sleep 1; say "composer verdict before send: $(fm_tmux_composer_state lab:w2)"
send t2 "Firstmate live check: run exactly this shell command now: touch $LAB/acted-t2 - then follow the mv instruction you were given for this message. Reply with one short line."
if waitfile "$LAB/acted-t2" 240 && waitfile "$LAB/state/t2.inbox/handled/001.msg" 60; then
  if grep -q ';;;\.\.\.---' <(tmux capture-pane -p -t lab:w2 -S -200); then say "S2 RESULT: FAIL (junk was submitted, not dropped)"; else say "S2 RESULT: PASS (exit $RC; junk dropped, worker acted and acked)"; fi
else say "S2 RESULT: FAIL"; fi
snap "S2 after" w2 20

fi
# S3: recovery fails (backend refuses the key) -> loud exit 4, counted, pages once at N=3
say; say "=== S3: clear-or-submit refused by the backend: countable skip + page at N ==="
launch w3 t3
tmux send-keys -t lab:w3 -l "held draft that cannot be cleared"
sleep 1; touch "$LAB/fault"
for n in 1 2 3 4; do send t3 "steer number $n"; say "  counter=$(cat "$LAB/state/t3.doorbell-skip" 2>/dev/null) paged-marker=$([ -e "$LAB/state/t3.doorbell-skip.paged" ]&&echo yes||echo no) wake-queue-pages=$(grep -c 'doorbell-skip: task=t3' "$LAB/state/.wake-queue" 2>/dev/null || echo 0)"; done
say "  wake queue rows:"; grep 'doorbell-skip' "$LAB/state/.wake-queue" 2>/dev/null | sed 's/^/    /' | tee -a "$LOG" >/dev/null
say "  inbox records (durable, none resent): $(ls "$LAB/state/t3.inbox" | grep -c '\.msg$')"
rm -f "$LAB/fault"
send t3 "steer number 5 (backend healthy again)"
say "  after healthy send: counter=$(cat "$LAB/state/t3.doorbell-skip" 2>/dev/null || echo absent) paged-marker=$([ -e "$LAB/state/t3.doorbell-skip.paged" ]&&echo yes||echo no)"
snap "S3 after recovery" w3 20

# S4: mid-turn agent with held text -> deferred, held text untouched, streak reset
say; say "=== S4: mid-turn agent: deferral leaves the composer alone ==="
launch w4 t4
tmux send-keys -t lab:w4 -l "Run this exact Bash tool command in the FOREGROUND (not background), it is required: timeout 60 tail -f /dev/null ; then reply DONE"; tmux send-keys -t lab:w4 Enter
i=0; while [ $i -lt 40 ]; do [ "$(fm_backend_busy_state tmux lab:w4 2>/dev/null)" = busy ] && break; sleep 1; i=$((i+1)); done; sleep 3
say "busy verdict: $(fm_backend_busy_state tmux lab:w4 2>/dev/null)"
tmux send-keys -t lab:w4 -l "queued draft keep me"
sleep 1; say "composer verdict before send: $(fm_tmux_composer_state lab:w4)"
echo 2 > "$LAB/state/t4.doorbell-skip"
say "busy verdict at send: $(fm_backend_busy_state tmux lab:w4 2>/dev/null)"
send t4 "steer while busy"
say "  composer still holds the draft: $(tmux capture-pane -p -t lab:w4 | grep -c 'queued draft keep me')"
say "  counter after deferral: $(cat "$LAB/state/t4.doorbell-skip" 2>/dev/null || echo absent)"
snap "S4 after" w4 12
