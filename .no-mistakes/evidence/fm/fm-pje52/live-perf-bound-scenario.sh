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

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name perf-bound)
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
BASE="$TMP_ROOT/base"; mkdir -p "$BASE"; git -C "$ROOT" archive 42dd906d02f672652606057a193a6386b956c3f3 bin | tar -x -C "$BASE"
run_with() { local bin=$1; shift; env "$@" FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" "$bin/fm-herdr-session-cleanup.sh"; }
S=$HOME_DIR/state
lab workspace create --cwd "$ROOT" --label captain-anchor --focus >/dev/null || fail anchor
K=15; N=150
for i in $(seq 1 $K); do lab workspace create --cwd "$ROOT" --label "└ cand-$i · p:CandTok$(printf %015d $i)" --no-focus >/dev/null || fail cand; done
seed() { for i in $(seq 1 $1); do printf 'version=1\ntask_id=dead-%s\nprojection_id=DeadTok%015d\n' "$i" "$i" > "$S/dead-$i.herdr-presentation"; done; }
seed $N
echo "layout: $K live candidate titles x $N accumulated journals"
t0=$SECONDS; run_with "$BASE/bin" >/dev/null 2>&1; tb=$((SECONDS-t0))
echo "BASE (42dd906d) cleanup: ${tb}s, journals left: $(ls $S/*.herdr-presentation | wc -l)"
t0=$SECONDS; OUT=$(run_with "$ROOT/bin" 2>&1); tn=$((SECONDS-t0))
echo "NEW (f8066865) cleanup: ${tn}s, journals left: $(ls $S/*.herdr-presentation 2>/dev/null | wc -l)"
echo "$OUT" | head -3
[ "$tn" -lt "$tb" ] || fail "new path not faster than base ($tn vs $tb)"
pass "index path faster than per-title rescan: ${tb}s -> ${tn}s"
for i in $(seq 1 $K); do lab workspace list | jq -e --arg l "└ cand-$i · p:CandTok$(printf %015d $i)" '[.result.workspaces[]|select(.label==$l)]|length==1' >/dev/null || fail "candidate $i touched"; done
pass "all $K live candidates untouched"
seed 600
t0=$SECONDS; OUT=$(run_with "$ROOT/bin" FM_HERDR_CLEANUP_BUDGET_SECS=2 2>&1); rc=$?; tb2=$((SECONDS-t0))
echo "budget=2s run: rc=$rc elapsed=${tb2}s left=$(ls $S/*.herdr-presentation | wc -l)"; echo "$OUT"
[ $rc = 0 ] || fail 'budget run nonzero'
echo "$OUT" | grep -q 'exceeded budget' || fail 'no early-exit warning'
[ "$tb2" -le 4 ] || fail "budget overrun ${tb2}s"
pass "cleanup stops early at its wall budget and still exits 0"
