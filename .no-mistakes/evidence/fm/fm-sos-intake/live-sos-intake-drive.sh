#!/usr/bin/env bash
# live-sos-intake-drive.sh - manual live product drive for branch fm/fm-sos-intake.
#
# Drives the REAL product end to end: bin/fm-sos-intake.sh -> bin/fm-tasks-axi.sh
# -> the machine's installed tasks-axi (0.2.6) and bd (1.3.0), plus the real
# fm-procevent-when.sh watch runner and fm-brief.sh. Only the external services
# are doubled: gh (GitHub), curl (the event bridge), fm-spawn (the crewmate
# launcher), plus an argv-logging transparent shim that execs the real
# tasks-axi so the transcript can show exactly which flags reached the tool.
#
# Prints one `ok - ...` / `NOT OK - ...` line per assertion and a final tally.
set -u

ROOT="/home/jon/.no-mistakes/worktrees/16b9fb59e3d9/01M3FT3W77PM32HSQ23M6W0HCX"
INTAKE="$ROOT/bin/fm-sos-intake.sh"
WRAP="$ROOT/bin/fm-tasks-axi.sh"
WHEN="$ROOT/bin/fm-procevent-when.sh"
UUID="7f3c1a52-9b41-4c2e-9d6a-1f0b2c3d4e5f"
TID="fm-sos-$UUID"
ISSUE=1921

PASSED=0
FAILED=0
ok()   { PASSED=$((PASSED + 1)); printf 'ok - %s\n' "$1"; }
bad()  { FAILED=$((FAILED + 1)); printf 'NOT OK - %s\n' "$1"; }
check() { # check <description> <command...>
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
ncheck() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi; }
has()    { grep -qF -- "$2" "$1" 2>/dev/null; }   # file contains fixed string
count_is() { [ "$(grep -c -- "$2" "$1" 2>/dev/null || true)" = "$3" ]; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-sos-live.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
CASE_DUE="+2w"
FB="$LAB/fakebin"
mkdir -p "$FB"
REAL_TASKS=$(command -v tasks-axi)
echo "=== lab: $LAB"
echo "=== real tasks-axi: $REAL_TASKS ($("$REAL_TASKS" --version 2>&1 | head -1))"
echo "=== real bd: $(command -v bd) ($(bd --version 2>&1 | head -1))"

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
      view)
        n="${3:-}"
        if [ -f "$FAKE/gh-state-$n" ]; then cat "$FAKE/gh-state-$n"; else echo '{"state":"OPEN"}'; fi ;;
      comment)
        n="${3:-}"; shift 3; body=""
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

cat > "$FB/curl" <<'SH'
#!/usr/bin/env bash
set -u
FAKE="${FM_SOS_FAKE_DIR:?}"
echo "curl $*" >> "$FAKE/curl.log"
cat "$FAKE/bridge.json"
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
chmod +x "$FB/gh" "$FB/curl" "$FB/fm-spawn" "$FB/tasks-axi"

# --- fixtures ----------------------------------------------------------------

set_event() { # <fakedir> <id> <uuid> <issue>
  cat > "$1/bridge.json" <<EOF
{"events":[{"id":$2,"kind":"sos","dedupeKey":"$3","at":"2026-09-26T12:00:00.000Z","receivedAt":"2026-09-26T12:00:01.000Z","site":"covenant","payload":{"ticket":"${3%%-*}","gh_issue":$4,"gh_issue_url":"https://github.com/ArcsHealth/Portal/issues/$4"}}],"cursor":$2,"backlog":0}
EOF
}
set_empty_bridge() { printf '{"events":[],"cursor":0,"backlog":0}\n' > "$1/bridge.json"; }
set_gh_open() { # <fakedir> <issue> <uuid>
  cat > "$1/gh-list.json" <<EOF
[{"number":$2,"url":"https://github.com/ArcsHealth/Portal/issues/$2","title":"SOS: reported problem","body":"### SOS Voice Ticket\n- **SOS ID:** \`$3\`\n"}]
EOF
}

# new_case <name> [beads] -> sets CASE_HOME / CASE_FD, echoes home|fd
new_case() {
  local name=$1 kind=${2:-md}
  CASE_HOME="$LAB/$name/home"
  CASE_FD="$LAB/$name/fake"
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
}

run_intake() { # <args...> ; stdout+stderr -> $CASE_OUT, rc -> $CASE_RC
  CASE_OUT=$(FM_HOME="$CASE_HOME" \
    FM_SOS_DUE="${CASE_DUE:-+2w}" \
    FM_SOS_FAKE_DIR="$CASE_FD" \
    FM_SOS_BRIDGE_URL="http://bridge.invalid:8791" \
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
echo "########## A. Idempotent pickup of one bridge event (markdown home, real tasks-axi)"
new_case pickled
run_intake reconcile
echo "--- pass 1 output:"; printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "pass 1 exits 0" || bad "pass 1 exits 0 (rc=$CASE_RC)"
case "$CASE_OUT" in *task_created=1*) ok "pass 1 creates the task row";; *) bad "pass 1 creates the task row";; esac
case "$CASE_OUT" in *dispatched=1*) ok "pass 1 dispatches one crewmate";; *) bad "pass 1 dispatches one crewmate";; esac
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
echo "--- argv the real tasks-axi received (add entry; the --body value is multi-line):"
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
echo "--- pass 3 (lost cursor + replayed event):"
rm -f "$CASE_HOME/state/fm-sos-intake.cursor"
set_event "$CASE_FD" 1 "$UUID" "$ISSUE"
run_intake reconcile
echo "--- pass 3 output:"; printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "replay pass exits 0" || bad "replay pass exits 0 (rc=$CASE_RC)"
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
check "the row stays closed after the re-run" bash -c "[ \"\$(FM_HOME='$CASE_HOME' '$WRAP' show '$TID' 2>/dev/null | sed -n 's/^  state: //p' | head -1)\" = done ]"

echo
echo "########## C. Adversarial: a failing spawn stays owed, then retries exactly once"
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
check "the dispatch guard is now recorded" count_is "$ledger" "dispatch key=" 1
run_intake reconcile >/dev/null
check "a third pass still launches nothing" count_is "$CASE_FD/spawn.log" "fm-spawn" 1

echo
echo "########## D. Adversarial: an event for a captain-closed issue keeps the row but no comment/dispatch"
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
[ "$(cat "$CASE_HOME/state/fm-sos-intake.cursor" 2>/dev/null)" = 1 ] && ok "the event is still consumed" || bad "the event is still consumed"

echo
echo "########## E. Adversarial: watch-condition never reads a failure as closed"
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
echo "########## F. dry-run reports the plan with no side effects; comment transitions are bounded"
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

echo
echo "########## G. Beads home with due governance: row created, due from the ladder, strip loud"
if command -v bd >/dev/null 2>&1; then
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
  DESC=$(cd "$CASE_HOME" && bd show "$TID" --json 2>/dev/null | python3 -c 'import json,sys
d = json.load(sys.stdin)
d = d[0] if isinstance(d, list) else d
print(d.get("description") or "")' 2>/dev/null) || DESC=""
  case "$DESC" in *"priority-why: staff SOS report awaiting fix"*) ok "the P1 why reached the beads record";; *) bad "the P1 why reached the beads record";; esac
  case "$CASE_OUT" in *"fm-tasks-axi: stripping --due/--why"*) ok "the stripped --due is reported loudly on beads too";; *) bad "the stripped --due is reported loudly on beads too";; esac
  echo "--- argv the real tasks-axi received (add entry):"
  grep -A4 "^tasks-axi add $TID" "$CASE_FD/tasks-argv.log" || true
  ncheck "the rejected --due never reached the real tasks-axi on beads" grep -q -- "--due" "$CASE_FD/tasks-argv.log"
else
  bad "bd not on PATH - beads scenario cannot run"
fi

echo
echo "########## H. fm-tasks-axi.sh gate: warning only when flags are asked for"
new_case gate
FM_HOME="$CASE_HOME" FM_SOS_FAKE_DIR="$CASE_FD" PATH="$FB:$PATH" \
  "$WRAP" add fm-gate-probe "probe row" --kind ship --repo portal --priority 1 \
  --due +2w --why "probe reason" --json >"$LAB/gate.out" 2>"$LAB/gate.err"
GRC=$?
echo "--- wrapper add rc=$GRC, stderr:"; cat "$LAB/gate.err"
[ "$GRC" = 0 ] && ok "wrapper add with both flags succeeds on the real tool" || bad "wrapper add with both flags succeeds on the real tool (rc=$GRC)"
check "the strip warning accompanies the add" has "$LAB/gate.err" "fm-tasks-axi: stripping --due/--why"
echo "--- full tasks-axi argv log for this case:"
cat "$CASE_FD/tasks-argv.log"
ncheck "--due was dropped before exec" grep -q -- "--due" "$CASE_FD/tasks-argv.log"
check "--why was passed through" grep -qF -- "--why probe reason" "$CASE_FD/tasks-argv.log"
check "the probe row exists" bash -c "FM_HOME='$CASE_HOME' '$WRAP' show fm-gate-probe >/dev/null"
FM_HOME="$CASE_HOME" FM_SOS_FAKE_DIR="$CASE_FD" PATH="$FB:$PATH" \
  "$WRAP" list >"$LAB/list.out" 2>"$LAB/list.err"
ncheck "a plain read emits no strip warning" grep -q "stripping" "$LAB/list.err"

echo
echo "########## I. status reports rows, watches, and reopened tickets"
run_intake status
echo "--- status:"; printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "status exits 0" || bad "status exits 0 (rc=$CASE_RC)"

echo
echo "########## J. Fork-like tool (help advertises --due/--why): both flags pass through and FM_SOS_DUE reaches the row"
FB2="$LAB/fakebin2"
mkdir -p "$FB2"
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

forkish_home() { # <name>: beads backend config (what fm-tasks-axi's gate keys on)
  new_case "$1"
  cat > "$CASE_HOME/.tasks.toml" <<'EOF'
backend = "beads"

[beads]
path = ".beads"
prefix = "fm"
EOF
}
row_due() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("due") or "")' "$CASE_FD/row.json" 2>/dev/null || true; }

CASE_PATH_PRE="$FB2:"
CASE_DUE="+2w"
forkish_home forkish
run_intake reconcile
echo "--- fork-like pass (default FM_SOS_DUE=+2w):"; printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "intake succeeds against a tool that accepts the flags" || bad "intake succeeds against a tool that accepts the flags (rc=$CASE_RC)"
nout=$(printf '%s' "$CASE_OUT" | grep -c "fm-tasks-axi: stripping" || true)
[ "${nout:-0}" = 0 ] && ok "no strip warning when the tool advertises the flags" || bad "no strip warning when the tool advertises the flags"
check "the due reached the fork-like tool" grep -qF -- "--due +2w" "$CASE_FD/tasks-argv.log"
check "the why reached the fork-like tool" grep -qF -- "--why staff SOS report awaiting fix" "$CASE_FD/tasks-argv.log"
[ "$(row_due)" = "+2w" ] && ok "the row's due equals the default FM_SOS_DUE (+2w)" || bad "the row's due equals the default FM_SOS_DUE (+2w), got '$(row_due)'"

echo "--- fork-like pass with an operator-set FM_SOS_DUE=+5d:"
CASE_DUE="+5d"
forkish_home forkish-due
run_intake reconcile
printf '%s\n' "$CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "intake succeeds with FM_SOS_DUE=+5d" || bad "intake succeeds with FM_SOS_DUE=+5d (rc=$CASE_RC)"
check "the operator's due reached the tool" grep -qF -- "--due +5d" "$CASE_FD/tasks-argv.log"
[ "$(row_due)" = "+5d" ] && ok "the row's due equals the operator-set FM_SOS_DUE (+5d)" || bad "the row's due equals the operator-set FM_SOS_DUE (+5d), got '$(row_due)'"
CASE_DUE="+2w"
CASE_PATH_PRE=""

echo
echo "########## K. Reopened-after-terminal: loud once, listed, and never re-dispatched"
new_case reopened
run_intake reconcile
echo "--- setup pass: $CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "setup pass dispatches the ticket" || bad "setup pass dispatches the ticket (rc=$CASE_RC)"
run_intake watch-fire "$ISSUE" "$UUID" >/dev/null
echo "--- captain closes: $CASE_OUT"
mkdir -p "$CASE_HOME/state/procevent-inbox"
cat > "$CASE_HOME/state/procevent-inbox/when-sos-$ISSUE.1.result" <<EOF
when: when-sos-$ISSUE
status: fired
detail: captain closed the issue
condition_polls: 3
action_exit: 0
EOF
rm -f "$CASE_HOME/state/procevent/when-sos-$ISSUE.source"
run_intake reconcile
echo "--- reopened pass: $CASE_OUT"
[ "$CASE_RC" = 0 ] && ok "the reopened pass succeeds" || bad "the reopened pass succeeds (rc=$CASE_RC)"
case "$CASE_OUT" in *"reopened-after-terminal key=$UUID issue=$ISSUE"*) ok "the reopen is reported with its exact class";; *) bad "the reopen is reported with its exact class";; esac
case "$CASE_OUT" in *dispatched=0*) ok "a reopened ticket is not re-dispatched";; *) bad "a reopened ticket is not re-dispatched";; esac
check "the reopen is recorded once in the ledger" count_is "$ledger" "reopened key=" 1
check "no second crewmate launched" count_is "$CASE_FD/spawn.log" "fm-spawn" 1
check "no second dispatched comment posted" count_is "$CASE_FD/comments.log" "SOS dispatch" 1
ncheck "a captured fired verdict is never re-armed" test -f "$CASE_HOME/state/procevent/when-sos-$ISSUE.source"
run_intake reconcile >/dev/null
echo "--- repeat pass: $CASE_OUT"
check "the reopen signal stays recorded once across repeat passes" count_is "$ledger" "reopened key=" 1
ncheck "a repeat pass does not repeat the signal" bash -c "printf '%s' \"\$0\" | grep -q 'reopened-after-terminal'" "$CASE_OUT"
run_intake status
check "status lists the reopened ticket" bash -c "printf '%s' \"\$0\" | grep -qF 'reopened key=$UUID issue=$ISSUE'" "$CASE_OUT"

echo
echo "=========================================================="
echo "DRIVE RESULT: passed=$PASSED failed=$FAILED"
[ "$FAILED" = 0 ]
