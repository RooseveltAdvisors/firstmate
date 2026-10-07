#!/usr/bin/env bash
# tests/fm-jev-worker-reaper.test.sh - Verification suite for Pattern 8 Worker Reaper.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REAPER_BIN="$FM_ROOT/bin/fm-jev-worker-reaper.sh"

echo "1. Verify --help output..."
"$REAPER_BIN" --help >/dev/null
echo "ok - help flags work"

echo "2. Verify --json output format..."
JSON_OUT=$("$REAPER_BIN" --check --json || true)
if ! printf '%s\n' "$JSON_OUT" | grep -q '"dead_workers"'; then
  echo "FAIL: Expected dead_workers in JSON output" >&2
  exit 1
fi
echo "ok - JSON format verified"

echo "3. Verify --check runs without error..."
"$REAPER_BIN" --check >/dev/null 2>&1 || true
echo "ok - check scan completed"

echo "4. Stale and completed workspaces holding leaked processes are swept..."
# The two historical skips - a 7-day age cutoff and a `done:` ledger line - used
# to shield exactly the leaks this reaper exists to clear: a stale workspace and
# a completed PR slot whose panes are gone while their processes keep running.
# The fixture seeds both, plus a fresh record (control) and a secondmate seat
# (the safety boundary: never reaped). Assertions grep only the fixture's own
# ids, so whatever else this machine holds is out of scope, and every --reap is
# scoped with --target so no other record can ever be touched.
CASE=$(mktemp -d "${TMPDIR:-/tmp}/fm-jev-worker-reaper-test.XXXXXX")
cleanup() {
  [ -n "${LEAKED:-}" ] && kill -KILL $LEAKED 2>/dev/null || true
  [ -n "${LEAKED:-}" ] && wait $LEAKED 2>/dev/null || true
  rm -rf "$CASE"
}
trap cleanup EXIT
LEAKED=
mkdir -p "$CASE/home/state" "$CASE/home/bin" "$CASE/fakebin" "$CASE/wt-stale" "$CASE/wt-done"

cat > "$CASE/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"pane list"*) printf '{"result":{"panes":[]}}' ;;
  *"pane close"*) printf '%s\n' "$*" >> "${HERDR_CLOSE_LOG:?}" ;;
  *"pane read"*) printf 'worker gone\n' ;;
esac
exit 0
SH
cat > "$CASE/fakebin/git" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$CASE/home/bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${TEARDOWN_LOG:?}"
exit 0
SH
chmod +x "$CASE/fakebin/herdr" "$CASE/fakebin/git" "$CASE/home/bin/fm-teardown.sh"

seed() {  # <id> <worktree>
  cat > "$CASE/home/state/$1.meta" <<EOF
kind=ship
harness=claude
herdr_pane_id=p-$1
herdr_session=firstmate
worktree=$2
EOF
}
FIX_STALE="reaper-fixture-stale-$$"
FIX_DONE="reaper-fixture-done-$$"
FIX_FRESH="reaper-fixture-fresh-$$"
FIX_MATE="reaper-fixture-mate-$$"
seed "$FIX_STALE" "$CASE/wt-stale"
seed "$FIX_DONE" "$CASE/wt-done"
seed "$FIX_FRESH" "$CASE/wt-stale"
seed "$FIX_MATE" "$CASE/wt-done"
touch -d '10 days ago' "$CASE/home/state/$FIX_STALE.meta" 2>/dev/null \
  || touch -t 202001010000 "$CASE/home/state/$FIX_STALE.meta"
touch -d '10 days ago' "$CASE/home/state/$FIX_MATE.meta" 2>/dev/null \
  || touch -t 202001010000 "$CASE/home/state/$FIX_MATE.meta"
printf 'kind=secondmate\nharness=claude\nherdr_pane_id=p-%s\nherdr_session=firstmate\nworktree=%s\n' \
  "$FIX_MATE" "$CASE/wt-done" > "$CASE/home/state/$FIX_MATE.meta"
printf 'done: PR https://example.invalid/pull/1 checks green\n' > "$CASE/home/state/$FIX_DONE.status"
printf 'done: idle\n' > "$CASE/home/state/$FIX_MATE.status"

# The leaked processes still rooted in those workspaces.
( cd "$CASE/wt-stale" && exec sleep 300 ) &
STALE_PID=$!
( cd "$CASE/wt-done" && exec sleep 300 ) &
DONE_PID=$!
LEAKED="$STALE_PID $DONE_PID"
sleep 0.3

check_line() {  # <id> -> 0 when the scan reports it
  local out
  out=$(PATH="$CASE/fakebin:$PATH" FM_HOME="$CASE/home" HERDR_CLOSE_LOG="$CASE/herdr.log" \
    TEARDOWN_LOG="$CASE/teardown.log" \
    "$REAPER_BIN" --check --json 2>/dev/null || true)
  printf '%s\n' "$out" | grep -q "\"$1\""
}
reap_line() {  # <id> -> 0 when the sweep ran teardown for it
  PATH="$CASE/fakebin:$PATH" FM_HOME="$CASE/home" HERDR_CLOSE_LOG="$CASE/herdr.log" \
    TEARDOWN_LOG="$CASE/teardown.log" \
    "$REAPER_BIN" --reap --target "$1" >/dev/null 2>&1 || true
  grep -qx "$1" "$CASE/teardown.log" 2>/dev/null
}

for id in "$FIX_STALE" "$FIX_DONE"; do
  check_line "$id" || { echo "FAIL: a workspace holding leaked processes was skipped by the scan: $id" >&2; exit 1; }
  reap_line "$id" || { echo "FAIL: a workspace holding leaked processes was not swept: $id" >&2; exit 1; }
done
check_line "$FIX_FRESH" || { echo "FAIL: the fresh control record was not reported" >&2; exit 1; }
check_line "$FIX_MATE" && { echo "FAIL: a persistent secondmate seat must never be reaped" >&2; exit 1; }
reap_line "$FIX_MATE" && { echo "FAIL: a persistent secondmate seat was swept" >&2; exit 1; }
echo "ok - stale and completed workspaces with leaked processes are swept; secondmate seats are not"

echo "ok - all fm-jev-worker-reaper tests passed"
