#!/usr/bin/env bash
# Behavior tests for durable verification receipts, domain routing, deduplication,
# refusal ordering, evidence preservation, and the test runner's recording hook.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-verification-record)
RECORDER="$ROOT/bin/fm-verification-record.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
export PATH="$FAKEBIN:$PATH"
export CALLS="$TMP_ROOT/calls"
export FM_HOME="$TMP_ROOT/home"
unset FM_VERIFICATION_DOMAIN FM_VERIFICATION_STORE FM_DATA_OVERRIDE
mkdir -p "$FM_HOME/.beads" "$FM_HOME/projects/portal/.beads" "$TMP_ROOT/wiseman/.beads"
printf 'screenshot or log\n' >"$TMP_ROOT/proof.png"

# A store-scoped CLI fake models only the public interface used by the recorder.
# Create's output deliberately lies: only list can supply a confirmed ID.
cat >"$FAKEBIN/bd" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s %s\n' "$BEADS_DIR" "$1" >>"$CALLS"
db="$BEADS_DIR/issues.json"
[ -f "$db" ] || printf '[]' >"$db"
op=$1; shift
id='' ref='' description='' note='' status=''
case "$op" in update|close) id=$1; shift ;; esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --external-ref) ref=$2; shift 2 ;;
    --description) description=$2; shift 2 ;;
    --append-notes) note=$2; shift 2 ;;
    --status) status=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$op" in
  where) jq -cn --arg path "${REDIRECT_STORE:-$BEADS_DIR}" '{path:$path}' ;;
  list)
    if [ "${HIDE_READBACK:-}" = 1 ] && [ "$(jq length "$db")" -gt 0 ]; then
      printf '[]'; exit 0
    fi
    jq --arg ref "$ref" '[.[] | select(.external_ref == $ref)]' "$db" ;;
  create)
    if [ "${REFUSE_CREATE:-}" = 1 ]; then
      printf 'ACTION_GATE: project_worker cannot bd create\n' >&2
      printf 'Create refusal detail on stdout\n'; exit 17
    fi
    jq --arg ref "$ref" --arg body "$description" \
      '. + [{id:("fixture-" + ((length + 1)|tostring)),external_ref:$ref,description:$body,notes:"",status:"open",updated_at:1}]' \
      "$db" >"$db.tmp"
    mv "$db.tmp" "$db"
    printf 'created ghost-not-a-real-id\n' ;;
  update)
    [ "${REFUSE_UPDATE:-}" != 1 ] || { echo 'ACTION_GATE: update denied' >&2; exit 18; }
    jq --arg id "$id" --arg note "$note" --arg status "$status" \
      'map(if .id == $id then .notes += ("\n" + $note) | .updated_at += 1
        | if $status != "" then .status = $status else . end else . end)' "$db" >"$db.tmp"
    mv "$db.tmp" "$db" ;;
  close)
    [ "${REFUSE_CLOSE:-}" != 1 ] || { echo 'ACTION_GATE: close denied' >&2; exit 19; }
    jq --arg id "$id" 'map(if .id == $id then .status = "closed" else . end)' "$db" >"$db.tmp"
    mv "$db.tmp" "$db" ;;
  *) echo "unexpected bd operation: $op" >&2; exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/bd"
[ -x "$RECORDER" ] || fail 'verification recorder must be executable'

record() {
  "$RECORDER" --task t1 --domain firstmate \
    --command 'visual QA: sidebar' --evidence "$TMP_ROOT/proof.png" "$@"
}
receipt=$(record)
expect_code 0 "$?" 'failure should create a bead'
[ "$(printf '%s' "$receipt" | jq -r .bead)" = fixture-1 ] || fail 'receipt used unconfirmed create output'
attachment=$(printf '%s' "$receipt" | jq -r .evidence)
cmp "$attachment" "$TMP_ROOT/proof.png" || fail 'screenshot bytes were not preserved'
assert_contains "$receipt" "$FM_HOME/.beads" 'receipt does not name the actual store'
case "$attachment" in "$FM_HOME/data/verification-evidence/"*) ;; *) fail "evidence left FM data: $attachment" ;; esac
[ ! -e "$FM_HOME/.beads/verification-evidence" ] || fail 'evidence was written into the tracked store'
printf 'second screenshot\n' >"$TMP_ROOT/proof.png"
receipt=$(record --evidence "$TMP_ROOT/./proof.png" --summary 'still rejected')
[ "$(printf '%s' "$receipt" | jq -r .action)" = updated ] || fail 'normalized duplicate was created'
[ "$(jq length "$FM_HOME/.beads/issues.json")" = 1 ] || fail 'rerun minted another bead'
[ "$(jq '.[0].updated_at' "$FM_HOME/.beads/issues.json")" = 2 ] || fail 'duplicate did not bump updated timestamp'
assert_contains "$(jq -r '.[0].notes' "$FM_HOME/.beads/issues.json")" 'still rejected' 'repeat evidence was lost'
assert_contains "$(cat "$attachment")" 'screenshot or log' 'first evidence was overwritten'
pass 'confirmed ID, immutable screenshot snapshot, normalized dedupe and append/update'

# Closed findings still dedupe and reopen; separate commands/tasks/evidence stay separate.
jq '.[0].status="closed"' "$FM_HOME/.beads/issues.json" >"$TMP_ROOT/closed"
mv "$TMP_ROOT/closed" "$FM_HOME/.beads/issues.json"
record >/dev/null
[ "$(jq -r '.[0].status' "$FM_HOME/.beads/issues.json")" = open ] || fail 'repeat failure left its bead closed'
record --command 'CI check' >/dev/null
record --task t2 >/dev/null
cp "$TMP_ROOT/proof.png" "$TMP_ROOT/other.png"
record --evidence "$TMP_ROOT/other.png" >/dev/null
[ "$(jq length "$FM_HOME/.beads/issues.json")" = 4 ] || fail 'dedupe tuple or closed matching is wrong'
pass 'dedupe reopens closed findings and distinguishes all three key fields'

receipt=$(record --resolve --evidence "$TMP_ROOT/absent.log")
[ -z "$receipt" ] || fail 'resolving an unrecorded key emitted a receipt'
[ "$(jq length "$FM_HOME/.beads/issues.json")" = 4 ] || fail 'resolve created a bead'
receipt=$(record --resolve)
[ "$(printf '%s' "$receipt" | jq -r .action)" = resolved ] || fail 'resolve did not confirm closing'
[ "$(jq -r '.[0].status' "$FM_HOME/.beads/issues.json")" = closed ] || fail 'resolve left the bead open'
[ -z "$(record --resolve)" ] || fail 'resolving a closed bead emitted a receipt'
record >/dev/null
if REFUSE_CLOSE=1 record --resolve >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then fail 'close refusal succeeded'; fi
assert_grep 'ACTION_GATE: close denied' "$TMP_ROOT/err" 'close refusal was suppressed'
[ "$(jq -r '.[0].status' "$FM_HOME/.beads/issues.json")" = open ] || fail 'refused close changed status'
pass 'resolve closes only an open match, never creates, and reports refusals'

(unset FM_HOME; "$RECORDER" --task t1 --domain fleet-tooling --store "$TMP_ROOT/wiseman" \
  --command 'no fm data' --evidence "$TMP_ROOT/proof.png" >/dev/null)
[ "$(cat "$TMP_ROOT/wiseman/.beads/verification-evidence/.gitignore")" = '*' ] || fail 'store fallback evidence is not ignored'
rm -rf "$TMP_ROOT/wiseman/.beads/issues.json" "$TMP_ROOT/wiseman/.beads/verification-evidence"
record --domain portal >/dev/null
record --domain fleet-tooling --store "$TMP_ROOT/wiseman" >/dev/null
[ "$(jq length "$FM_HOME/projects/portal/.beads/issues.json")" = 1 ] || fail 'Portal finding used wrong store'
[ "$(jq length "$TMP_ROOT/wiseman/.beads/issues.json")" = 1 ] || fail 'fleet tooling finding used wrong store'
pass 'fallback evidence ignores itself; defect domains use distinct stores'

if REFUSE_CREATE=1 record --command 'new refusal' >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then fail 'gate refusal succeeded'; fi
[ ! -s "$TMP_ROOT/out" ] || fail 'refused create emitted a receipt'
assert_grep 'ACTION_GATE: project_worker cannot bd create' "$TMP_ROOT/err" 'gate stderr was suppressed'
assert_grep 'Create refusal detail on stdout' "$TMP_ROOT/err" 'gate stdout was suppressed'
assert_grep 'task=t1 command=new refusal' "$TMP_ROOT/err" 'refusal lost owning task/command'
if HIDE_READBACK=1 record --command 'readback refusal' >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then fail 'missing readback succeeded'; fi
[ ! -s "$TMP_ROOT/out" ] || fail 'unconfirmed create emitted a receipt'
if REFUSE_UPDATE=1 record >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then fail 'update refusal succeeded'; fi
[ ! -s "$TMP_ROOT/out" ] || fail 'refused update emitted a receipt'
if record --task '../escape' >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then fail 'unsafe task accepted'; fi
if record --store "$TMP_ROOT/absent" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then fail 'absent domain store fell back'; fi
if record --evidence "$TMP_ROOT/missing.png" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then fail 'missing evidence accepted'; fi
if REDIRECT_STORE="$TMP_ROOT/wiseman/.beads" record >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then fail 'store redirect was accepted'; fi
assert_no_grep '"bead":' "$TMP_ROOT/out" 'redirect emitted a receipt'
mkdir "$FM_HOME/.beads/.fm-verification-record.lock"
if record >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then fail 'held recording lock was stolen'; fi
rmdir "$FM_HOME/.beads/.fm-verification-record.lock"
pass 'gate, update, readback, store, ID and lock refusals emit no receipt'

# A fixture runner outside any git repo exercises the hook without creating
# another worktree of the shared project or touching any live Beads store.
repo="$TMP_ROOT/runner"
mkdir -p "$repo/bin" "$repo/tests"
cp "$ROOT/bin/fm-test-run.sh" "$RECORDER" "$repo/bin/"
cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
printf 'echo "not ok - sidebar"\nexit 1\n' >"$repo/tests/probe.test.sh"
if FM_TASK_ID=runner1 "$repo/bin/fm-test-run.sh" "$repo/tests/probe.test.sh" >"$TMP_ROOT/run" 2>&1; then fail 'red suite returned green'; fi
receipt_line=$(awk '/"bead":/ { print NR; exit }' "$TMP_ROOT/run")
end_line=$(awk '/^FM_TEST_END/ { print NR; exit }' "$TMP_ROOT/run")
[ -n "$receipt_line" ] && [ -n "$end_line" ] && [ "$receipt_line" -lt "$end_line" ] || fail "bead was not confirmed before the failure result: $(cat "$TMP_ROOT/run")"
assert_present "$FM_HOME/data/runner1/verification/probe.test.sh.log" 'failed log did not survive cleanup'
before=$(jq length "$FM_HOME/.beads/issues.json")
if FM_TASK_ID=runner1 "$repo/bin/fm-test-run.sh" "$repo/tests/probe.test.sh" >"$TMP_ROOT/run" 2>&1; then fail 'repeat red suite returned green'; fi
[ "$(jq length "$FM_HOME/.beads/issues.json")" = "$before" ] || fail 'runner rerun created duplicate bead'
log="$FM_HOME/data/runner1/verification/probe.test.sh.log"
[ "$(grep -c '^Run: ' "$log")" = 1 ] || fail 'runner evidence log accumulated earlier runs'
if REFUSE_CREATE=1 FM_TASK_ID=runner2 "$repo/bin/fm-test-run.sh" "$repo/tests/probe.test.sh" >"$TMP_ROOT/run" 2>&1; then fail 'filing refusal hid red suite'; fi
assert_grep 'ACTION_GATE: project_worker cannot bd create' "$TMP_ROOT/run" 'runner suppressed gate refusal'
assert_no_grep '"bead":' "$TMP_ROOT/run" 'refused runner claimed a bead'
assert_present "$FM_HOME/data/runner2/verification/probe.test.sh.log" 'refused runner lost its evidence'
printf 'echo "ok - sidebar"\n' >"$repo/tests/probe.test.sh"
FM_TASK_ID=runner1 "$repo/bin/fm-test-run.sh" "$repo/tests/probe.test.sh" >"$TMP_ROOT/run" 2>&1
[ "$(jq length "$FM_HOME/.beads/issues.json")" = "$before" ] || fail 'green runner created a bead'
assert_grep '"action":"resolved"' "$TMP_ROOT/run" 'green runner did not resolve the red-first bead'
[ "$(jq -r --arg ref "$(jq -r '.[-1].external_ref' "$FM_HOME/.beads/issues.json")" \
  '[.[] | select(.external_ref == $ref)][0].status' "$FM_HOME/.beads/issues.json")" = closed ] || fail 'red-first bead stayed open'
printf 'echo "ok - other"\n' >"$repo/tests/other.test.sh"
FM_TASK_ID=runner1 "$repo/bin/fm-test-run.sh" "$repo/tests/other.test.sh" >"$TMP_ROOT/run" 2>&1
[ "$(jq length "$FM_HOME/.beads/issues.json")" = "$before" ] || fail 'green script without a failure created a bead'
pass 'runner confirms bead before failure marker, keeps current-run logs, dedupes reruns, and closes on green'
echo '# all verification-record tests passed'
