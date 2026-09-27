#!/usr/bin/env bash
# round3-live-sos-intake-drive.sh - manual LIVE product drive for branch
# fm/fm-sos-intake (target ecb942a5).
#
# Drives the REAL product end to end in a throwaway lab home:
#   bin/fm-sos-intake.sh -> bin/fm-tasks-axi.sh -> the machine's installed
#   tasks-axi (0.2.6) and bd (1.3.0), the real fm-procevent-when.sh watch
#   runner and fm-brief.sh, and REAL curl over a REAL local HTTP event bridge
#   (a python http.server speaking the bridge contract the script documents:
#   GET /api/events?kind=sos&after=<cursor>).
# Only the two external services are doubled, both by the product's own
# documented override interfaces:
#   gh      - doubling GitHub itself (no production ArcsHealth/Portal writes
#             are permitted from this gate; a close attempt is trapped, exit 97)
#   fm-spawn- doubling the crewmate launcher (a real crewmate would run the
#             brief against the real repo; FM_SOS_SPAWN exists for this)
# plus an argv-logging transparent shim that execs the real tasks-axi, so the
# transcript shows exactly which flags reached the tool.
#
# Prints one `ok - ` / `NOT OK - ` line per assertion and a final tally.
set -u

ROOT="/home/jon/.no-mistakes/worktrees/16b9fb59e3d9/01M3FT3W77PM32HSQ23M6W0HCX"
INTAKE="$ROOT/bin/fm-sos-intake.sh"
WRAP="$ROOT/bin/fm-tasks-axi.sh"
WHEN="$ROOT/bin/fm-procevent-when.sh"
UUID="7f3c1a52-9b41-4c2e-9d6a-1f0b2c3d4e5f"
TID="fm-sos-$UUID"
ISSUE=1921

PASSED=0; FAILED=0
ok()   { PASSED=$((PASSED + 1)); printf 'ok - %s\n' "$1"; }
bad()  { FAILED=$((FAILED + 1)); printf 'NOT OK - %s\n' "$1"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
ncheck(){ local d=$1; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
has()   { grep -qF -- "$2" "$1" 2>/dev/null; }
count_is(){ [ "$(grep -c -- "$2" "$1" 2>/dev/null || true)" = "$3" ]; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-sos-live3.XXXXXX")
BRIDGE_PID=""
cleanup() { [ -n "$BRIDGE_PID" ] && kill "$BRIDGE_PID" 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
CASE_DUE="+2w"
CASE_PATH_PRE=""
FB="$LAB/fakebin"; mkdir -p "$FB"
REAL_TASKS=$(command -v tasks-axi)
echo "=== lab: $LAB"
echo "=== real tasks-axi: $REAL_TASKS ($("$REAL_TASKS" --version 2>&1 | head -1))"
echo "=== real curl: $(command -v curl)"
echo "=== real bd: $(command -v bd) ($(bd --version 2>&1 | head -1))"

# --- REAL local HTTP event bridge -------------------------------------------
cat > "$LAB/bridge.py" <<'PY'
import json, os, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

state_dir, portfile = sys.argv[1], sys.argv[2]

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # we write our own access log
        pass
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if os.path.exists(os.path.join(state_dir, "bridge-down")):
            with open(os.path.join(state_dir, "bridge-access.log"), "a") as f:
                f.write("GET %s -> 500\n" % self.path)
            self.send_response(500); self.end_headers()
            self.wfile.write(b'{"error":"bridge down"}')
            return
        after = int((q.get("after") or ["0"])[0])
        try:
            events = json.load(open(os.path.join(state_dir, "bridge-events.json")))
        except Exception:
            events = []
        kept = [e for e in events if int(e.get("id", 0)) > after]
        body = json.dumps({"events": kept, "cursor": after, "backlog": 0}).encode()
        with open(os.path.join(state_dir, "bridge-access.log"), "a") as f:
            f.write("GET %s -> 200 (%d events)\n" % (self.path, len(kept)))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

srv = HTTPServer(("127.0.0.1", 0), Handler)
with open(portfile, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PY

start_bridge() { # <fakedir>
  [ -n "$BRIDGE_PID" ] && { kill "$BRIDGE_PID" 2>/dev/null; wait "$BRIDGE_PID" 2>/dev/null; BRIDGE_PID=""; }
  rm -f "$LAB/bridge.port"
  python3 "$LAB/bridge.py" "$1" "$LAB/bridge.port" &
  BRIDGE_PID=$!
  local i=0
  while [ ! -s "$LAB/bridge.port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  BRIDGE_URL="http://127.0.0.1:$(cat "$LAB/bridge.port")"
  echo "=== bridge up at $BRIDGE_URL (pid $BRIDGE_PID) for $1"
}
stop_bridge() { [ -n "$BRIDGE_PID" ] && { kill "$BRIDGE_PID" 2>/dev/null; wait "$BRIDGE_PID" 2>/dev/null; BRIDGE_PID=""; }; }

# --- doubled external services ----------------------------------------------

cat > "$FB/gh" <<'SH'
#!/usr/bin/env bash
set -u
FAKE="${FM_SOS_FAKE_DIR:?}"
echo "gh $*" >> "$FAKE/gh.log"
if [ -f "$FAKE/gh-broken" ]; then echo "gh: simulated outage" >&2; exit 1; fi
case "${1:-}" in
  issue)
    case "${2:-}" in
      list) cat "$FAKE/gh-list.json" 2>/dev/null || echo "[]" ;;
      view) n="${3:-}"
            if [ -f "$FAKE/gh-state-$n" ]; then cat "$FAKE/gh-state-$n"; else echo '{"state":"OPEN"}'; fi ;;
      comment) n="${3:-}"; shift 3; body=""
            while [ $# -gt 0 ]; do
              if [ "$1" = "--body" ] && [ $# -ge 2 ]; then body="$2"; shift; fi
              shift
            done
            printf '%s\t%s\n' "$n" "$body" >> "$FAKE/comments.log"
            echo "https://github.com/ArcsHealth/Portal/issues/$n#comment-1" ;;
      close) echo "CLOSE-ATTEMPTED" >> "$FAKE/gh.log"; exit 97 ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
SH

cat > "$FB/fm-spawn" <<'SH'
#!/usr/bin/env bash
set -u
FAKE="${FM_SOS_FAKE_DIR:?}"
if [ -f "$FAKE/spawn-broken" ]; then echo "error: spawn cannot start" >&2; exit 1; fi
echo "fm-spawn $*" >> "$FAKE/spawn.log"
exit 0
SH

# Transparent argv logger: records every invocation, then execs the real tool.
cat > "$FB/tasks-axi" <<SH
#!/usr/bin/env bash
echo "tasks-axi \$*" >> "\${FM_SOS_FAKE_DIR:?}/tasks-argv.log"
exec "$REAL_TASKS" "\$@"
SH
chmod +x "$FB/gh" "$FB/fm-spawn" "$FB/tasks-axi"

# --- fixtures ----------------------------------------------------------------

set_event() { # <fakedir> <id> <uuid> <issue>
  cat > "$1/bridge-events.json" <<EOF
[{"id":$2,"kind":"sos","dedupeKey":"$3","at":"2026-09-26T12:00:00.000Z","receivedAt":"2026-09-26T12:00:01.000Z","site":"covenant","payload":{"ticket":"${3%%-*}","gh_issue":$4,"gh_issue_url":"https://github.com/ArcsHealth/Portal/issues/$4"}}]
EOF
}
set_empty_bridge() { printf '[]\n' > "$1/bridge-events.json"; }
set_gh_open() { # <fakedir> <issue> <uuid>
  cat > "$1/gh-list.json" <<EOF
[{"number":$2,"url":"https://github.com/ArcsHealth/Portal/issues/$2","title":"SOS: reported problem","body":"### SOS Voice Ticket\n- **SOS ID:** \`$3\`\n"}]
EOF
}

new_case() { # <name> [beads] -> CASE_HOME / CASE_FD / ledger / BRIDGE_URL
  local name=$1 kind=${2:-md}
  CASE_HOME="$LAB/$name/home"; CASE_FD="$LAB/$name/fake"
  mkdir -p "$CASE_HOME/data" "$CASE_FD"
  (umask 077; mkdir -p "$CASE_HOME/state")
  if [ "$kind" = beads ]; then
    cat > "$CASE_HOME/.tasks.toml" <<'EOF'
backend = "beads"

[beads]
path = ".beads"
prefix = "fm"
EOF
    (cd "$CASE_HOME" && bd init --prefix fm >/dev/null 2>&1)
    printf '\ndue:\n    required: true\n' >> "$CASE_HOME/.beads/config.yaml"
  else
    cp "$ROOT/.tasks.toml" "$CASE_HOME/.tasks.toml"
  fi
  set_event "$CASE_FD" 1 "$UUID" "$ISSUE"
  set_gh_open "$CASE_FD" "$ISSUE" "$UUID"
  ledger="$CASE_HOME/state/fm-sos-intake.log"
  start_bridge "$CASE_FD"
}

run_intake() { # <args...> ; stdout+stderr -> $CASE_OUT, rc -> $CASE_RC
  CASE_OUT=$(FM_HOME="$CASE_HOME" \
    FM_SOS_DUE="${CASE_DUE:-+2w}" \
    FM_SOS_FAKE_DIR="$CASE_FD" \
    FM_SOS_BRIDGE_URL="$BRIDGE_URL" \
    FM_SOS_TASKS="$WRAP" \
    FM_SOS_SPAWN="$FB/fm-spawn" \
    FM_SOS_BRIEF="$ROOT/bin/fm-brief.sh" \
    FM_SOS_WHEN="$WHEN" \
    PATH="${CASE_PATH_PRE:-}$FB:$PATH" \
    "$INTAKE" "$@" 2>&1)
  CASE_RC=$?
}
row_state() { FM_HOME="$CASE_HOME" "$WRAP" show "$1" 2>/dev/null | sed -n 's/^  state: //p' | head -1; }

echo
echo "########## A. Idempotent pickup of one bridge event over REAL HTTP (markdown home, real tasks-axi)"
new_case pickled
run_intake reconcile
echo "--- pass 1 output:"; printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "pass 1 exits 0" || bad "pass 1 exits 0 (rc=$CASE_RC)"
case "$CASE_OUT" in *task_created=1*) ok "pass 1 creates the task row";; *) bad "pass 1 creates the task row";; esac
case "$CASE_OUT" in *dispatched=1*) ok "pass 1 dispatches one crewmate";; *) bad "pass 1 dispatches one crewmate";; esac
check "the intake really polled the bridge over HTTP" has "$CASE_FD/bridge-access.log" "after=0"
check "the row fm-sos-<uuid> exists in the real backlog" bash -c "FM_HOME='$CASE_HOME' '$WRAP' show '$TID' >/dev/null"
[ "$(row_state "$TID")" = queued ] && ok "a fresh row sits queued" || bad "a fresh row sits queued (state=$(row_state "$TID"))"
ncheck "no fallback-key row was minted for the same ticket" bash -c "FM_HOME='$CASE_HOME' '$WRAP' show 'fm-sos-gh-issue-$ISSUE' >/dev/null"
check "exactly one dispatched comment posted" count_is "$CASE_FD/comments.log" "SOS dispatch" 1
check "the comment names the task row" has "$CASE_FD/comments.log" "$TID"
check "the comment states the never-closes rule" has "$CASE_FD/comments.log" "never closes it"
check "exactly one crewmate spawned" count_is "$CASE_FD/spawn.log" "fm-spawn" 1
check "spawn carries the delivery mode" has "$CASE_FD/spawn.log" "--mode no-mistakes"
check "close-watch spec armed" test -f "$CASE_HOME/state/when/when-sos-$ISSUE.spec"
check "close-watch trust record armed" test -f "$CASE_HOME/state/when/when-sos-$ISSUE.trust"
[ "$(cat "$CASE_HOME/state/fm-sos-intake.cursor" 2>/dev/null)" = 1 ] && ok "cursor advanced to event id 1" || bad "cursor advanced to event id 1"
ncheck "the loop never closed the GitHub issue" grep -q "issue close" "$CASE_FD/gh.log"
check "brief scaffolded with the ticket intent" has "$CASE_HOME/data/$TID/brief.md" "Resolve the staff SOS reported in ArcsHealth/Portal#$ISSUE"
ncheck "brief carries no unfilled placeholders" grep -q "{TASK}\|{FIRSTMATE_SPEC}" "$CASE_HOME/data/$TID/brief.md"
echo "--- strip warning seen on pass 1:"
printf '%s\n' "$CASE_OUT" | grep -F "fm-tasks-axi: stripping" || echo "(NO WARNING)"
case "$CASE_OUT" in *"fm-tasks-axi: stripping --due/--why: installed tasks-axi does not accept them (due not applied to row)"*) ok "a stripped --due is reported loudly, not silently";; *) bad "a stripped --due is reported loudly, not silently";; esac
echo "--- argv the real tasks-axi received:"
grep -A4 "^tasks-axi add fm-sos-" "$CASE_FD/tasks-argv.log" || true
ncheck "the rejected --due never reached the real tasks-axi" grep -q -- "--due" "$CASE_FD/tasks-argv.log"
check "the accepted --why did reach the real tasks-axi" grep -qF -- "--why staff SOS report awaiting fix" "$CASE_FD/tasks-argv.log"
check "row carries the P1 why from the tool" bash -c "FM_HOME='$CASE_HOME' '$WRAP' show '$TID' 2>/dev/null | grep -q 'staff SOS report awaiting fix'"

echo
echo "--- pass 2 (bridge drained):"
set_empty_bridge "$CASE_FD"
run_intake reconcile
echo "--- pass 2 output:"; printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "pass 2 exits 0" || bad "pass 2 exits 0 (rc=$CASE_RC)"
case "$CASE_OUT" in *task_created=0*) ok "pass 2 creates no second row";; *) bad "pass 2 creates no second row";; esac
case "$CASE_OUT" in *dispatched=0*) ok "pass 2 does not re-dispatch";; *) bad "pass 2 does not re-dispatch";; esac
check "still exactly one comment after pass 2" count_is "$CASE_FD/comments.log" "SOS dispatch" 1
check "still exactly one spawn after pass 2" count_is "$CASE_FD/spawn.log" "fm-spawn" 1

echo
echo "--- pass 3 (lost cursor + replayed event over real HTTP):"
rm -f "$CASE_HOME/state/fm-sos-intake.cursor"
set_event "$CASE_FD" 1 "$UUID" "$ISSUE"
run_intake reconcile
echo "--- pass 3 output:"; printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "replay pass exits 0" || bad "replay pass exits 0 (rc=$CASE_RC)"
check "the replay really re-polled the bridge from cursor 0" has "$CASE_FD/bridge-access.log" "after=0"
case "$CASE_OUT" in *task_created=0*) ok "replay creates no second row";; *) bad "replay creates no second row";; esac
case "$CASE_OUT" in *dispatched=0*) ok "replay does not re-dispatch";; *) bad "replay does not re-dispatch";; esac
check "still exactly one dispatched comment after replay" count_is "$CASE_FD/comments.log" "SOS dispatch" 1
check "still exactly one spawn after replay" count_is "$CASE_FD/spawn.log" "fm-spawn" 1
[ "$(cat "$CASE_HOME/state/fm-sos-intake.cursor" 2>/dev/null)" = 1 ] && ok "cursor re-consumed to event id 1" || bad "cursor re-consumed to event id 1"
check "ledger records exactly one dispatch" count_is "$ledger" "dispatch key=" 1

echo
echo "########## B. watch-fire: closes the row once, never the GitHub issue"
run_intake watch-fire "$ISSUE" "$UUID"
echo "--- watch-fire 1:"; printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "watch-fire exits 0" || bad "watch-fire exits 0 (rc=$CASE_RC)"
case "$CASE_OUT" in *captain-closed*) ok "watch-fire reports the close";; *) bad "watch-fire reports the close";; esac
[ "$(row_state "$TID")" = done ] && ok "the task row closed" || bad "the task row closed (state=$(row_state "$TID"))"
check "captain-closed comment posted once" count_is "$CASE_FD/comments.log" "Closed by the captain" 1
ncheck "watch-fire never closed the GitHub issue" grep -q "issue close" "$CASE_FD/gh.log"
run_intake watch-fire "$ISSUE" "$UUID"
echo "--- watch-fire 2:"; printf '%s\n' "$CASE_OUT"
case "$CASE_OUT" in *already-closed-recorded*) ok "a re-run is a recorded no-op";; *) bad "a re-run is a recorded no-op";; esac
check "the close comment still posted exactly once" count_is "$CASE_FD/comments.log" "Closed by the captain" 1

echo
echo "########## C. GitHub heal path: the event never arrives (bridge down), then the event shows up - exactly one dispatch across both paths"
new_case healed
touch "$CASE_FD/bridge-down"   # real HTTP 500 for every poll
set_empty_bridge "$CASE_FD"    # and no event ever published
run_intake reconcile
echo "--- healed pass (bridge down, issue listed):"; printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "the heal pass exits 0 under a bridge outage" || bad "the heal pass exits 0 under a bridge outage (rc=$CASE_RC)"
case "$CASE_OUT" in *dispatched=1*) ok "the listed open issue is dispatched without any event";; *) bad "the listed open issue is dispatched without any event";; esac
check "the bridge really answered 500 on that poll" has "$CASE_FD/bridge-access.log" "-> 500"
rm -f "$CASE_FD/bridge-down"
set_event "$CASE_FD" 1 "$UUID" "$ISSUE"   # the lost event finally shows up
run_intake reconcile
echo "--- event arrives later:"; printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "the follow-up pass exits 0" || bad "the follow-up pass exits 0 (rc=$CASE_RC)"
case "$CASE_OUT" in *dispatched=0*) ok "the late event does not re-dispatch";; *) bad "the late event does not re-dispatch";; esac
check "exactly one comment across heal + event" count_is "$CASE_FD/comments.log" "SOS dispatch" 1
check "exactly one spawn across heal + event" count_is "$CASE_FD/spawn.log" "fm-spawn" 1
check "exactly one dispatch in the ledger across heal + event" count_is "$ledger" "dispatch key=" 1

echo
echo "########## D. Adversarial: a failing spawn stays owed, then retries exactly once"
new_case spawnfail
touch "$CASE_FD/spawn-broken"
run_intake reconcile
echo "--- failing pass:"; printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" = 1 ] && ok "a failed spawn fails the pass (rc=1)" || bad "a failed spawn fails the pass (rc=1, got $CASE_RC)"
case "$CASE_OUT" in *"failed: dispatch"*) ok "the spawn failure reaches the operator";; *) bad "the spawn failure reaches the operator";; esac
ncheck "no dispatch guard recorded for the failed spawn" grep -q "dispatch key=" "$ledger"
ncheck "no crewmate launched" test -f "$CASE_FD/spawn.log"
rm -f "$CASE_FD/spawn-broken"
run_intake reconcile
echo "--- retry pass:"; printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "the retry pass succeeds" || bad "the retry pass succeeds (rc=$CASE_RC)"
case "$CASE_OUT" in *dispatched=1*) ok "the owed dispatch runs on the retry";; *) bad "the owed dispatch runs on the retry";; esac
check "exactly one crewmate across both passes" count_is "$CASE_FD/spawn.log" "fm-spawn" 1
run_intake reconcile >/dev/null
check "a third pass still launches nothing" count_is "$CASE_FD/spawn.log" "fm-spawn" 1

echo
echo "########## E. Adversarial: an event for a captain-closed issue keeps the row but no comment/dispatch"
new_case closed
printf '[]\n' > "$CASE_FD/gh-list.json"
echo '{"state":"CLOSED"}' > "$CASE_FD/gh-state-$ISSUE"
run_intake reconcile
echo "--- pass:"; printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "the pass succeeds" || bad "the pass succeeds (rc=$CASE_RC)"
case "$CASE_OUT" in *"skip: #$ISSUE is closed"*) ok "the closed ticket is reported skipped";; *) bad "the closed ticket is reported skipped";; esac
check "the row is still ensured" bash -c "FM_HOME='$CASE_HOME' '$WRAP' show '$TID' >/dev/null"
check "the close watch is still armed" test -f "$CASE_HOME/state/when/when-sos-$ISSUE.spec"
ncheck "no dispatched comment on a closed ticket" test -f "$CASE_FD/comments.log"
ncheck "no crewmate for a closed ticket" test -f "$CASE_FD/spawn.log"
ncheck "the intake never closed the GitHub issue itself" grep -q "issue close" "$CASE_FD/gh.log"
[ "$(cat "$CASE_HOME/state/fm-sos-intake.cursor" 2>/dev/null)" = 1 ] && ok "the event is still consumed" || bad "the event is still consumed"

echo
echo "########## F. Adversarial: watch-condition never reads a failure as closed"
new_case cond
run_intake watch-condition "$ISSUE"; echo "OPEN issue rc=$CASE_RC"
[ "$CASE_RC" = 1 ] && ok "open issue is a clean false (rc=1)" || bad "open issue is a clean false (rc=1, got $CASE_RC)"
echo '{"state":"CLOSED"}' > "$CASE_FD/gh-state-$ISSUE"
run_intake watch-condition "$ISSUE"; echo "CLOSED issue rc=$CASE_RC"
[ "$CASE_RC" = 0 ] && ok "closed issue is a clean true (rc=0)" || bad "closed issue is a clean true (rc=0, got $CASE_RC)"
touch "$CASE_FD/gh-broken"
run_intake watch-condition "$ISSUE"; echo "gh outage rc=$CASE_RC"
[ "$CASE_RC" = 2 ] && ok "a gh outage fails closed (rc=2)" || bad "a gh outage fails closed (rc=2, got $CASE_RC)"
echo "unparseable:" > "$CASE_FD/gh-state-$ISSUE"
run_intake watch-condition "$ISSUE"; echo "garbage rc=$CASE_RC"
[ "$CASE_RC" = 2 ] && ok "an unparseable answer fails closed (rc=2)" || bad "an unparseable answer fails closed (rc=2, got $CASE_RC)"

echo
echo "########## G. fm-tasks-axi.sh capability gate against the REAL installed tool (0.2.6: help has --why, no --due)"
new_case gate
FM_HOME="$CASE_HOME" FM_SOS_FAKE_DIR="$CASE_FD" PATH="$FB:$PATH" \
  "$WRAP" add fm-gate-probe "probe row" --kind ship --repo portal --priority 1 \
  --due +2w --why "probe reason" --json >"$LAB/gate.out" 2>"$LAB/gate.err"
GRC=$?
echo "--- wrapper add rc=$GRC, stderr:"; cat "$LAB/gate.err"
[ "$GRC" = 0 ] && ok "wrapper add with both flags succeeds on the real tool" || bad "wrapper add with both flags succeeds on the real tool (rc=$GRC)"
check "the strip warning accompanies the add" has "$LAB/gate.err" "fm-tasks-axi: stripping --due/--why"
echo "--- full tasks-axi argv log for this case:"; cat "$CASE_FD/tasks-argv.log"
ncheck "--due was dropped before exec" grep -q -- "--due" "$CASE_FD/tasks-argv.log"
check "--why was passed through" grep -qF -- "--why probe reason" "$CASE_FD/tasks-argv.log"
check "the probe row exists" bash -c "FM_HOME='$CASE_HOME' '$WRAP' show fm-gate-probe >/dev/null"
FM_HOME="$CASE_HOME" FM_SOS_FAKE_DIR="$CASE_FD" PATH="$FB:$PATH" \
  "$WRAP" list >"$LAB/list.out" 2>"$LAB/list.err"
ncheck "a plain read emits no strip warning" grep -q "stripping" "$LAB/list.err"

echo
echo "########## H. Fork-like tool (help advertises --due/--why): both flags pass through and FM_SOS_DUE reaches the row"
FB2="$LAB/fakebin2"; mkdir -p "$FB2"
cat > "$FB2/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
FAKE="${FM_SOS_FAKE_DIR:?}"
echo "tasks-axi $*" >> "$FAKE/tasks-argv.log"
if [ "${1:-}" = add ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'flags: --kind <k>, --repo <n>, --priority <0-4>' '  --why "<one line>"' '  --due <date>'
  exit 0
fi
if [ "${1:-}" = add ]; then
  due=""; prev=""
  for a in "$@"; do
    case "$prev" in --due) due="$a" ;; esac
    case "$a" in --due=*) due="${a#--due=}" ;; esac
    prev="$a"
  done
  printf '{"id":"%s","due":"%s"}\n' "$2" "$due" > "$FAKE/row.json"
  printf '{"ok":true,"action":"add","already":false}\n'
  exit 0
fi
[ "${1:-}" = show ] && printf '  state: queued\n'
exit 0
SH
chmod +x "$FB2/tasks-axi"
forkish_home() { new_case "$1"; cat > "$CASE_HOME/.tasks.toml" <<'EOF'
backend = "beads"

[beads]
path = ".beads"
prefix = "fm"
EOF
}
row_due() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("due") or "")' "$CASE_FD/row.json" 2>/dev/null || true; }

CASE_PATH_PRE="$FB2:"
forkish_home forkish
run_intake reconcile
echo "--- fork-like pass (default FM_SOS_DUE=+2w):"; printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "intake succeeds against a tool that accepts the flags" || bad "intake succeeds against a tool that accepts the flags (rc=$CASE_RC)"
nout=$(printf '%s' "$CASE_OUT" | grep -c "fm-tasks-axi: stripping" || true)
[ "${nout:-0}" = 0 ] && ok "no strip warning when the tool advertises the flags" || bad "no strip warning when the tool advertises the flags"
check "the due reached the fork-like tool" grep -qF -- "--due +2w" "$CASE_FD/tasks-argv.log"
check "the why reached the fork-like tool" grep -qF -- "--why staff SOS report awaiting fix" "$CASE_FD/tasks-argv.log"
[ "$(row_due)" = "+2w" ] && ok "the row's due equals the default FM_SOS_DUE (+2w)" || bad "the row's due equals the default FM_SOS_DUE (+2w), got '$(row_due)'"
CASE_DUE="+5d"
forkish_home forkish-due
run_intake reconcile
echo "--- fork-like pass with operator FM_SOS_DUE=+5d:"; printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "intake succeeds with FM_SOS_DUE=+5d" || bad "intake succeeds with FM_SOS_DUE=+5d (rc=$CASE_RC)"
check "the operator's due reached the tool" grep -qF -- "--due +5d" "$CASE_FD/tasks-argv.log"
[ "$(row_due)" = "+5d" ] && ok "the row's due equals the operator-set FM_SOS_DUE (+5d)" || bad "the row's due equals the operator-set FM_SOS_DUE (+5d), got '$(row_due)'"
CASE_DUE="+2w"; CASE_PATH_PRE=""

echo
echo "########## I. Beads home with due governance: row created, due from the ladder, strip loud"
new_case beads beads
run_intake reconcile
echo "--- beads pass:"; printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "intake succeeds on a due-required beads home" || bad "intake succeeds on a due-required beads home (rc=$CASE_RC)"
case "$CASE_OUT" in *task_created=1*) ok "the beads row was created";; *) bad "the beads row was created";; esac
DUE_AT=$(cd "$CASE_HOME" && bd show "$TID" --json 2>/dev/null | python3 -c 'import json,sys
d = json.load(sys.stdin)
d = d[0] if isinstance(d, list) else d
print(d.get("due_at") or "")' 2>/dev/null) || DUE_AT=""
[ -n "$DUE_AT" ] && ok "the row carries a due under due governance ($DUE_AT)" || bad "the row carries a due under due governance"
case "$CASE_OUT" in *"fm-tasks-axi: stripping --due/--why"*) ok "the stripped --due is reported loudly on beads too";; *) bad "the stripped --due is reported loudly on beads too";; esac

echo
echo "########## J. dry-run reports the plan with no side effects; comment transitions are bounded"
new_case misc
run_intake reconcile --dry-run
echo "--- dry-run:"; printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "dry-run exits 0" || bad "dry-run exits 0"
case "$CASE_OUT" in *would-create*) ok "dry-run reports the plan";; *) bad "dry-run reports the plan";; esac
ncheck "dry-run creates no row" bash -c "FM_HOME='$CASE_HOME' '$WRAP' show '$TID' >/dev/null"
ncheck "dry-run does not move the cursor" test -f "$CASE_HOME/state/fm-sos-intake.cursor"
ncheck "dry-run posts no comment" test -f "$CASE_FD/comments.log"
ncheck "dry-run spawns nothing" test -f "$CASE_FD/spawn.log"
run_intake comment "$ISSUE" fix-up "PR https://github.com/ArcsHealth/Portal/pull/1"
echo "--- comment fix-up:"; printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "a valid transition comment posts" || bad "a valid transition comment posts"
check "the canonical label is used" has "$CASE_FD/comments.log" "Fix up"
run_intake comment "$ISSUE" nonsense
echo "--- comment nonsense:"; printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" -ne 0 ] && ok "an unknown transition is refused" || bad "an unknown transition is refused"
[ "$(grep -c '' "$CASE_FD/comments.log" 2>/dev/null || true)" = 1 ] && ok "the refused transition posted nothing" || bad "the refused transition posted nothing"
run_intake status >/dev/null
[ "$CASE_RC" = 0 ] && ok "status exits 0" || bad "status exits 0"

stop_bridge
echo
echo "=========================================================="
echo "DRIVE RESULT: passed=$PASSED failed=$FAILED"
[ "$FAILED" = 0 ]
