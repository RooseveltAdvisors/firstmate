#!/usr/bin/env bash
# Live driver: real Claude secondmate on an isolated Herdr lab session; the
# worker is mid-turn (native herdr busy verdict) with held composer text, and
# the real fm-send must DEFER (exit 0, held text untouched, streak reset).
set -u
ROOT=${ROOT:?}; EV=${EV:?}
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
. "$ROOT/bin/fm-backend.sh"
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
SESSION=$("$LAB_HELPER" name cdoorbell)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); TMP=$(cd "$TMP" && pwd)
LAB="$TMP/home"; SECOND="$TMP/second"; FAKEBIN="$TMP/fakebin"; ORIGINAL_PATH=$PATH
LOG="$EV/live-herdr-deferral-transcript.txt"; : > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
cleanup() { "$LAB_HELPER" teardown "$SESSION" >>"$LOG" 2>&1 || say "TEARDOWN FAILED"; rm -rf "$TMP"; }
trap cleanup EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<W
#!/usr/bin/env bash
args=("\$@"); n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
fi
PATH="$ORIGINAL_PATH" exec "$LAB_HELPER" run "$SESSION" "\${args[@]}"
W
chmod +x "$FAKEBIN/herdr"
git clone -q --no-hardlinks "$ROOT" "$SECOND"; git -C "$SECOND" checkout -q --detach HEAD
mkdir -p "$SECOND/state" "$SECOND/data" "$SECOND/config" "$SECOND/projects"
printf 'cd-sm\n' > "$SECOND/.fm-secondmate-home"
printf '# Isolated doorbell test secondmate\n\nStay idle. Do not initiate work. Only do what you are explicitly asked.\n' > "$SECOND/data/charter.md"
"$LAB_HELPER" provision "$SESSION" >>"$LOG" 2>&1 || { say "provision failed"; exit 1; }
say "=== herdr lab session $SESSION; claude $(claude --version|head -1) ==="
PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$LAB" HERDR_SESSION="$SESSION" "$ROOT/bin/fm-spawn.sh" cd-sm "$SECOND" --secondmate --harness claude --backend herdr >>"$LOG" 2>&1 || { say "spawn failed"; exit 1; }
META="$LAB/state/cd-sm.meta"; TARGET=$(fm_backend_target_of_meta "$META"); PANE=${TARGET#*:}
say "spawned target=$TARGET"
status() { "$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty'; }
read_pane() { "$LAB_HELPER" run "$SESSION" pane read "$PANE" 2>/dev/null | jq -r '.result.text // .result.content // .' 2>/dev/null | grep '[^[:space:]]' | tail -${1:-14}; }
i=0; s=0; while [ $i -lt 240 ]; do case "$(status)" in idle|done) s=$((s+1)); [ $s -ge 6 ] && break;; *) s=0;; esac; sleep 1; i=$((i+1)); done
say "agent status before busy turn: $(status)"
"$LAB_HELPER" run "$SESSION" pane send-text "$PANE" "Run this exact Bash command in the FOREGROUND (never background): timeout 60 tail -f /dev/null ; then reply DONE" >/dev/null
"$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" enter >/dev/null
i=0; while [ $i -lt 40 ]; do [ "$(status)" = working ] && break; sleep 1; i=$((i+1)); done; sleep 4
"$LAB_HELPER" run "$SESSION" pane send-text "$PANE" "queued draft keep me" >/dev/null
sleep 1
say "agent status at send: $(status)"
echo 2 > "$LAB/state/cd-sm.doorbell-skip"; say "seeded consecutive-skip counter: 2"
RC=0; PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$LAB" "$ROOT/bin/fm-send.sh" cd-sm "steer while mid-turn" >"$TMP/out" 2>"$TMP/err" || RC=$?
say "\$ fm-send.sh cd-sm 'steer while mid-turn' -> exit $RC"; sed 's/^/  stderr: /' "$TMP/err" | tee -a "$LOG" >/dev/null
say "counter after send: $(cat "$LAB/state/cd-sm.doorbell-skip" 2>/dev/null || echo absent)"
say "inbox records: $(ls "$LAB/state/cd-sm.inbox" 2>/dev/null | tr '\n' ' ')"
say "----- pane after send -----"; read_pane 16 | tee -a "$LOG" >/dev/null
