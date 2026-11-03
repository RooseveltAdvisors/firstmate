#!/usr/bin/env bash
# Throwaway manual driver (test-phase evidence, NOT repo source).
# Reuses tests/fm-kimi-harness.test.sh's fixture helpers (extracted unmodified
# except for two harness-state additions) to drive the REAL bin/fm-spawn.sh
# against the committed Kimi 2.1.1 capture under tests/captures/kimi-2.1.1/.
#
# Scenario A: a 2.1.1 folder prompt announcing project MCP servers receives
#            no key, the brief pointer is never sent, and the declared MCP
#            command never starts (fm-spawn refuses).
# Scenario B: the same 2.1.1 dialog wording WITHOUT the MCP disclosure is
#            answered exactly once and the brief is delivered (the refusal in
#            A is caused by the announcement, not by the 2.1.1 dialog words).
set -u
EV=${EV:-/home/jon/.no-mistakes/evidence/01M6GEXF94WWY182KQG94QDBY2}
ROOT={run-worktree}
LIB=/tmp/fm211/driver-lib.sh
CAPS=/tmp/fm211/captures

# shellcheck source=/dev/null
. "$LIB"

FAILURES=0
check() {  # <ok?> <label>
  if [ "$1" = ok ]; then
    printf 'ok - %s\n' "$2"
  else
    printf 'NOT OK - %s\n' "$2"
    FAILURES=$((FAILURES + 1))
  fi
}

echo "=== Scenario A: 2.1.1 announcing prompt -> fm-spawn refuses ==="
id=kimi-211-rootmcp-m1
rec=$(make_spawn_case trust-211-rootmcp "$id")
read_spawn_record "$rec"
rc=0
out=$(FM_KIMI_READY_POLLS=3 FM_FAKE_KIMI_TRUST=211-rootmcp DRIVER_CAPTURES="$CAPS" run_spawn \
  "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
printf '%s\n' "$out"
echo "--- A observable side effects ---"
echo "exit code: $rc"
echo "trust-enter.log: [$(cat "$CASE_DIR/trust-enter.log" 2>/dev/null)]"
echo "pointer.log:     [$(cat "$CASE_DIR/pointer.log" 2>/dev/null)]"
echo "marker.log:      [$(cat "$CASE_DIR/marker.log" 2>/dev/null)]"
echo "status:          [$(cat "$HOME_DIR/state/$id.status" 2>/dev/null)]"
[ "$rc" -ne 0 ] && check ok "A: spawn refused (exit $rc)" || check fail "A: spawn refused (exit $rc)"
[ ! -s "$CASE_DIR/trust-enter.log" ] && check ok "A: no Enter key sent to the 2.1.1 announcing prompt" \
  || check fail "A: no Enter key sent to the 2.1.1 announcing prompt"
[ ! -s "$CASE_DIR/pointer.log" ] && check ok "A: brief pointer never delivered" \
  || check fail "A: brief pointer never delivered"
[ ! -s "$CASE_DIR/marker.log" ] && check ok "A: declared project MCP command never started" \
  || check fail "A: declared project MCP command never started"
case "$out" in
  *"announces project MCP servers"*) check ok "A: refusal names the announcement" ;;
  *) check fail "A: refusal names the announcement" ;;
esac

echo
echo "=== Scenario B (adversarial control): same 2.1.1 dialog words, no MCP disclosure -> answered once ==="
id=kimi-211-plain-m2
rec=$(make_spawn_case trust-211-plain "$id")
read_spawn_record "$rec"
rc=0
out=$(FM_KIMI_READY_POLLS=3 FM_FAKE_KIMI_TRUST=211-plain DRIVER_CAPTURES="$CAPS" run_spawn \
  "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
printf '%s\n' "$out"
echo "--- B observable side effects ---"
echo "exit code: $rc"
echo "trust-enter.log: [$(cat "$CASE_DIR/trust-enter.log" 2>/dev/null)]"
echo "pointer.log:     [$(cat "$CASE_DIR/pointer.log" 2>/dev/null)]"
echo "marker.log:      [$(cat "$CASE_DIR/marker.log" 2>/dev/null)]"
[ "$rc" -eq 0 ] && check ok "B: spawn completed (exit $rc)" || check fail "B: spawn completed (exit $rc)"
[ "$(wc -l < "$CASE_DIR/trust-enter.log" | tr -d ' ')" = 1 ] \
  && check ok "B: plain 2.1.1 dialog answered exactly once" || check fail "B: plain 2.1.1 dialog answered exactly once"
grep -q 'Read the brief at' "$CASE_DIR/pointer.log" \
  && check ok "B: brief pointer delivered" || check fail "B: brief pointer delivered"
[ ! -s "$CASE_DIR/marker.log" ] && check ok "B: no MCP command started for a plain dialog" \
  || check fail "B: no MCP command started for a plain dialog"

echo
echo "RESULT: $FAILURES failure(s)"
exit "$FAILURES"
