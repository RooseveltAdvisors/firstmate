#!/usr/bin/env bash
# Real restored-shell E2E for home-local session-start Herdr projection cleanup.
# Every CLI operation is routed through one guarded named non-default lab, and
# lab teardown verifies that the default fleet session is byte-identical.
set -u

ROOT=/home/jon/.no-mistakes/worktrees/46339c0817e0/01M43MR3CCEX596GAHYNVGJT2B
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-session-cleanup-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/config"
touch "$HOME_DIR/config/herdr-presentation-spaces"
printf '%s\n' herdr > "$HOME_DIR/config/backend"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name prune-live)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

# Keep the lab helper as the only CLI transport. Production adapter calls have
# already appended the exact session; this shim strips that pair, refuses every
# other caller-supplied session, and delegates the command to helper run.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
run_cleanup() { FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" "$ROOT/bin/fm-herdr-session-cleanup.sh"; }
S=$HOME_DIR/state
ANCHOR=$(lab workspace create --cwd "$ROOT" --label captain-anchor --focus) || fail anchor
ANCHOR_TAB=$(printf '%s' "$ANCHOR" | jq -r .result.tab.tab_id)
# 1) stale idle projection (positive cleanup target)
STOK=StaleTok1234567890abcd; SID=stale-idle
C=$(lab workspace create --cwd "$ROOT" --label "└ $SID · p:$STOK" --no-focus) || fail create-stale
SWS=$(printf '%s' "$C" | jq -r .result.workspace.workspace_id); SPANE=$(printf '%s' "$C" | jq -r .result.root_pane.pane_id)
printf 'version=1\ntask_id=%s\nprojection_id=%s\n' "$SID" "$STOK" > "$S/$SID.herdr-presentation"
# 2) LIVE projection, no meta, busy shell -> journal must survive prune
LTOK=LiveTok12345678901abcd; LID=live-busy
C=$(lab workspace create --cwd "$ROOT" --label "└ $LID · p:$LTOK" --no-focus) || fail create-live
LWS=$(printf '%s' "$C" | jq -r .result.workspace.workspace_id); LPANE=$(printf '%s' "$C" | jq -r .result.root_pane.pane_id)
printf 'version=1\ntask_id=%s\nprojection_id=%s\n' "$LID" "$LTOK" > "$S/$LID.herdr-presentation"
# 3) 300 accumulated dead journals
for i in $(seq 1 300); do printf 'version=1\ntask_id=dead-%s\nprojection_id=DeadTok%015d\n' "$i" "$i" > "$S/dead-$i.herdr-presentation"; done
# 4) dead journal with held spawn lock -> survives
printf 'version=1\ntask_id=dead-locked\nprojection_id=LockedTok1234567890abc\n' > "$S/dead-locked.herdr-presentation"
"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail stop
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null || fail reprovision
lab tab focus "$ANCHOR_TAB" >/dev/null || fail refocus
sleep 2
lab pane run "$LPANE" "sleep 600" >/dev/null || fail run-live
# real live-owner spawn lock held by a background process
FM_HOME="$HOME_DIR" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2" || exit 3; sleep 120' _ "$ROOT" "$S/.spawn-dead-locked.lock" &
HOLDER=$!
sleep 4
[ -e "$S/.spawn-dead-locked.lock" ] || fail 'holder did not take lock'
echo "before: $(ls "$S"/*.herdr-presentation | wc -l) journals"
start=$(date +%s.%N)
OUT=$(run_cleanup 2>&1) || fail cleanup-failed
end=$(date +%s.%N)
echo "cleanup output: $OUT"
echo "elapsed: $(echo "$end - $start" | bc)s"
echo "after: $(ls "$S"/*.herdr-presentation | wc -l) journals: $(ls "$S" | grep presentation | tr '\n' ' ')"
[ "$(ls "$S"/dead-[0-9]*.herdr-presentation 2>/dev/null | wc -l)" = 0 ] || fail 'dead journals not pruned'
pass 'all 300 dead journals pruned in one pass'
[ -f "$S/$LID.herdr-presentation" ] || fail 'LIVE projection journal pruned'
lab workspace get "$LWS" >/dev/null || fail 'live workspace touched'
lab pane get "$LPANE" >/dev/null || fail 'live pane touched'
pass 'live busy projection: journal kept, workspace+pane untouched'
[ -f "$S/dead-locked.herdr-presentation" ] && [ -e "$S/.spawn-dead-locked.lock" ] || fail 'locked dead journal pruned or lock touched'
pass 'dead journal under held spawn lock survives'
! lab pane get "$SPANE" >/dev/null 2>&1 || fail 'stale idle pane survived'
[ ! -e "$S/$SID.herdr-presentation" ] || fail 'stale journal survived'
pass 'stale idle projection closed and its journal removed in same pass'
OUT2=$(run_cleanup 2>&1) || fail repeat
[ -f "$S/$LID.herdr-presentation" ] || fail 'live journal pruned on repeat'
pass "repeat pass idempotent (output: ${OUT2:-<none>})"
kill $HOLDER 2>/dev/null
