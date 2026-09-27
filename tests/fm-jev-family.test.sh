#!/usr/bin/env bash
# Behavior tests for the Jev-consulting family: bin/fm-jev-lib.sh and its two
# new members, bin/fm-alert-route.sh and bin/fm-seat-state-advise.sh.
#
# The client is a fake curl on PATH, so every case drives the real tools through
# their public argv and environment interface without a network call. What is
# asserted is the family's safety shape rather than the model's taste:
#
#   - Off means no network call at all, and still a useful answer.
#   - The key reaches curl on a file descriptor and never on argv.
#   - A deterministic answer is never sent to the model.
#   - Every failure is fail-open in that tool's own safe direction, exit 0.
#   - Telemetry and calibration carry no ids and no content.
#   - The seat advisor can never express a relaunch authorization.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP=$(fm_test_tmproot fm-jev-family)
ROUTE="$ROOT/bin/fm-alert-route.sh"
ADVISE="$ROOT/bin/fm-seat-state-advise.sh"
KEY=test-key-not-a-real-secret

command -v jq >/dev/null 2>&1 || { pass 'fm-jev-family: skipped, jq is not installed'; exit 0; }

# A fake curl that records how it was called and answers with a chosen body.
# LOG/argv proves whether curl ran at all; LOG/header proves where the key went.
fake_curl() {  # <dir> <http-code> <body>
  local dir=$1 code=$2 body=$3 fakebin
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/log"
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> '$dir/log/argv'
out=''
prev=''
for a in "\$@"; do
  [ "\$prev" = -o ] && out=\$a
  case "\$a" in @/dev/fd/3) cat /dev/fd/3 >> '$dir/log/header' 2>/dev/null || true ;; esac
  prev=\$a
done
cat >> '$dir/log/body' 2>/dev/null || true
[ -z "\$out" ] || printf '%s' '$body' > "\$out"
printf '%s' '$code'
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

answer() {  # <question> <choice> <confidence> <probs-json>
  printf '{"answers":{"%s":{"choice":"%s","confidence":%s,"probabilities":%s}},"usage":{"input_tokens":10,"output_tokens":2}}' \
    "$1" "$2" "$3" "$4"
}

# --- item (a): a unique namespace claim is placed with no model call ---------
A=$(mktemp -d "$TMP/route.XXXXXX")
mkdir -p "$A/data" "$A/state"
cat > "$A/data/secondmates.md" <<'REG'

- monitor-sre - Watches the monitor. (home: /nope; scope: rails prefixed monitor. or the monitor service itself; projects: monitoring; added 2026-01-01)
- gpu-ops - Watches the GPU host. (home: /nope; scope: all monitoring rails under gpu.* and svc.* prefixes; projects: monitoring; added 2026-01-01)
- other-ops - Also mentions gpu. things. (home: /nope; scope: remediation of gpu.loom_capture.freshness.* only; projects: x; added 2026-01-01)
REG
FB=$(fake_curl "$A/c1" 200 "$(answer charter gpu-ops 0.9 '{"monitor-sre":0.02,"gpu-ops":0.9,"other-ops":0.08}')")
OUT=$(PATH="$FB:$BASE_PATH" TYPESAFE_API_KEY="$KEY" FM_HOME="$A" \
  FM_STATE_OVERRIDE="$A/state" FM_DATA_OVERRIDE="$A/data" "$ROUTE" monitor.public_url 2>&1)
expect_code 0 $? 'a routed alert exits 0'
assert_contains "$OUT" 'status: clear' 'a unique namespace claim is a clear answer'
assert_contains "$OUT" 'owner: monitor-sre' 'the seat that claims the namespace owns the alert'
assert_contains "$OUT" 'source: exact' 'the answer is attributed to exact matching'
assert_absent "$A/c1/log/argv" 'an exactly matched alert is never sent to the model'

# --- a contested claim goes to the model, and only then ----------------------
# gpu. is claimed by two seats here, which is a real ambiguity rather than a
# match, so this must consult the model instead of picking one.
OUT=$(PATH="$FB:$BASE_PATH" TYPESAFE_API_KEY="$KEY" FM_HOME="$A" \
  FM_STATE_OVERRIDE="$A/state" FM_DATA_OVERRIDE="$A/data" "$ROUTE" gpu.repo_drift 2>&1)
assert_contains "$OUT" 'status: clear' 'a confident model answer over a contested claim is clear'
assert_contains "$OUT" 'owner: gpu-ops' 'the model breaks the tie between the competing claims'
assert_contains "$OUT" 'source: model' 'the answer is attributed to the model'
assert_present "$A/c1/log/argv" 'a contested claim does reach the model'
assert_contains "$(command cat "$A/c1/log/header")" "Authorization: Bearer $KEY" \
  'the key reaches curl on the file descriptor header'
assert_not_contains "$(command cat "$A/c1/log/argv")" "$KEY" 'the key never appears on argv'

# --- off means no call, and still an owner ----------------------------------
B=$(mktemp -d "$TMP/off.XXXXXX")
mkdir -p "$B/data" "$B/state"
cp "$A/data/secondmates.md" "$B/data/secondmates.md"
FB2=$(fake_curl "$B/c" 200 "$(answer charter gpu-ops 0.9 '{"monitor-sre":0.02,"gpu-ops":0.9,"other-ops":0.08}')")
OUT=$(PATH="$FB2:$BASE_PATH" FM_HOME="$B" FM_STATE_OVERRIDE="$B/state" \
  FM_DATA_OVERRIDE="$B/data" "$ROUTE" gpu.repo_drift 2>&1)
expect_code 0 $? 'the off path exits 0'
assert_contains "$OUT" 'alert-route: off' 'the off notice names the tool'
assert_absent "$B/c/log/argv" 'an absent key never calls curl'
assert_contains "$OUT" 'status: escalate' 'an unplaceable alert with the model off escalates'
assert_contains "$OUT" 'owner: captain' 'the escalation names the fallback owner'

# --- an alert is never dropped, whatever fails ------------------------------
for code in 500 000; do
  C=$(mktemp -d "$TMP/fail$code.XXXXXX")
  mkdir -p "$C/data" "$C/state"
  cp "$A/data/secondmates.md" "$C/data/secondmates.md"
  FB3=$(fake_curl "$C/c" "$code" 'upstream is unhappy')
  OUT=$(PATH="$FB3:$BASE_PATH" TYPESAFE_API_KEY="$KEY" FM_HOME="$C" \
    FM_STATE_OVERRIDE="$C/state" FM_DATA_OVERRIDE="$C/data" "$ROUTE" gpu.repo_drift 2>&1)
  expect_code 0 "$?" "an http $code failure still exits 0"
  assert_contains "$OUT" 'status: unavailable' "an http $code failure is unavailable rather than an error"
  assert_contains "$OUT" 'owner: captain' "an http $code failure still names an owner"
done

# A malformed answer is not half-trusted.
D=$(mktemp -d "$TMP/malformed.XXXXXX")
mkdir -p "$D/data" "$D/state"
cp "$A/data/secondmates.md" "$D/data/secondmates.md"
FB4=$(fake_curl "$D/c" 200 '{"answers":{"charter":{"choice":"gpu-ops"}}}')
OUT=$(PATH="$FB4:$BASE_PATH" TYPESAFE_API_KEY="$KEY" FM_HOME="$D" \
  FM_STATE_OVERRIDE="$D/state" FM_DATA_OVERRIDE="$D/data" "$ROUTE" gpu.repo_drift 2>&1)
assert_contains "$OUT" 'status: unavailable' 'an answer missing its confidence is unavailable'
assert_contains "$OUT" 'owner: captain' 'a malformed answer still names an owner'

# An answer naming an option that was never offered is refused too.
E=$(mktemp -d "$TMP/offmenu.XXXXXX")
mkdir -p "$E/data" "$E/state"
cp "$A/data/secondmates.md" "$E/data/secondmates.md"
FB5=$(fake_curl "$E/c" 200 "$(answer charter invented-seat 0.99 '{"monitor-sre":0.02,"gpu-ops":0.9,"other-ops":0.08}')")
OUT=$(PATH="$FB5:$BASE_PATH" TYPESAFE_API_KEY="$KEY" FM_HOME="$E" \
  FM_STATE_OVERRIDE="$E/state" FM_DATA_OVERRIDE="$E/data" "$ROUTE" gpu.repo_drift 2>&1)
assert_contains "$OUT" 'status: unavailable' 'a choice outside the offered options is refused'
assert_not_contains "$OUT" 'owner: invented-seat' 'an off-menu choice never becomes an owner'

# --- below the floor the alert escalates with its ranking, never routes ------
F=$(mktemp -d "$TMP/floor.XXXXXX")
mkdir -p "$F/data" "$F/state"
cp "$A/data/secondmates.md" "$F/data/secondmates.md"
FB6=$(fake_curl "$F/c" 200 "$(answer charter gpu-ops 0.4 '{"monitor-sre":0.3,"gpu-ops":0.4,"other-ops":0.3}')")
OUT=$(PATH="$FB6:$BASE_PATH" TYPESAFE_API_KEY="$KEY" FM_HOME="$F" \
  FM_STATE_OVERRIDE="$F/state" FM_DATA_OVERRIDE="$F/data" "$ROUTE" gpu.repo_drift 2>&1)
assert_contains "$OUT" 'status: ambiguous' 'a low-confidence answer is ambiguous'
assert_contains "$OUT" 'owner: captain' 'a low-confidence answer escalates rather than routing on a guess'
assert_contains "$OUT" 'best: gpu-ops' 'the escalation carries the model ranking as evidence'

# --- no registry is still not a dropped alert -------------------------------
G=$(mktemp -d "$TMP/noreg.XXXXXX")
mkdir -p "$G/state" "$G/data"
OUT=$(FM_HOME="$G" FM_STATE_OVERRIDE="$G/state" FM_DATA_OVERRIDE="$G/data" "$ROUTE" gpu.repo_drift 2>&1)
expect_code 0 $? 'a missing registry still exits 0'
assert_contains "$OUT" 'status: escalate' 'a missing registry escalates'
assert_contains "$OUT" 'owner: captain' 'a missing registry still names an owner'

# A usage error is actionable rather than routed around.
OUT=$(FM_HOME="$G" FM_STATE_OVERRIDE="$G/state" FM_DATA_OVERRIDE="$G/data" "$ROUTE" 2>&1)
expect_code 2 $? 'a missing alert name is a usage error'

# --- telemetry and calibration carry no ids and no content ------------------
TEL="$A/state/.alert-route-telemetry"
assert_present "$TEL" 'a decision writes one telemetry line'
assert_not_contains "$(command cat "$TEL")" 'monitor.public_url' 'telemetry carries no alert name'
assert_not_contains "$(command cat "$TEL")" 'gpu.repo_drift' 'telemetry carries no alert name at all'
CAL="$A/state/.alert-route-calibration.jsonl"
assert_present "$CAL" 'a model decision writes one calibration line'
assert_not_contains "$(command cat "$CAL")" 'gpu.repo_drift' 'calibration carries no alert name'
printf '%s\n' "$(command cat "$CAL")" | jq -e '.confidence and .choice' >/dev/null \
  || fail 'each calibration line is one JSON object with the decision and its confidence'

# The calibration file is bounded, so an always-on tool cannot grow it forever.
H=$(mktemp -d "$TMP/cap.XXXXXX")
mkdir -p "$H/data" "$H/state"
cp "$A/data/secondmates.md" "$H/data/secondmates.md"
FB7=$(fake_curl "$H/c" 200 "$(answer charter gpu-ops 0.9 '{"monitor-sre":0.02,"gpu-ops":0.9,"other-ops":0.08}')")
printf '{"filler":1}\n{"filler":2}\n' > "$H/state/.alert-route-calibration.jsonl"
PATH="$FB7:$BASE_PATH" TYPESAFE_API_KEY="$KEY" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" \
  FM_DATA_OVERRIDE="$H/data" FM_JEV_CALIBRATION_MAX=2 "$ROUTE" gpu.repo_drift >/dev/null 2>&1
assert_equals 2 "$(awk 'END {print NR}' "$H/state/.alert-route-calibration.jsonl")" \
  'calibration stops at its cap instead of growing without bound'

# --- item (b): a conclusive probe is never sent to the model ----------------
# A fake tmux drives the endpoint classification, the same shape the liveness
# suite establishes; the session prefix is stripped because tmux lists names.
fake_tmux() {  # <dir> <state> <window>
  local dir=$1 state=$2 win=${3#*:} fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    case '$state' in
      alive) printf '%s\n' pi ;;
      ambiguous) printf '%s\n' node ;;
      dead) printf '%s\n' bash ;;
    esac
    exit 0 ;;
  list-windows) printf '%s\n' '$win'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

seat_home() {  # <dir> <seat> <probe-state>
  local root=$1 seat=$2 st=$3
  mkdir -p "$root/state" "$root/lanes/$seat/state"
  fm_write_secondmate_meta "$root/state/$seat.meta" "$root/lanes/$seat" "sess:$seat" alpha pi
  printf '%s\n' "$st" > /dev/null
}

I=$(mktemp -d "$TMP/advise-alive.XXXXXX")
seat_home "$I" seat alive
CB=$(fake_curl "$I/c" 200 "$(answer seat_state true_wedge 0.99 '{"pipeline_wait":0.005,"true_wedge":0.99,"healthy_idle":0.005}')")
TB=$(fake_tmux "$I/t" alive sess:seat)
OUT=$(PATH="$TB:$CB:$BASE_PATH" TYPESAFE_API_KEY="$KEY" FM_HOME="$I" \
  FM_STATE_OVERRIDE="$I/state" "$ADVISE" seat 2>&1)
expect_code 0 $? 'a conclusive probe exits 0'
assert_contains "$OUT" 'probe: alive' 'a live endpoint is reported as such'
assert_contains "$OUT" 'source: deterministic' 'a conclusive probe is answered deterministically'
assert_absent "$I/c/log/argv" 'a conclusive probe is never sent to the model'

# --- an inconclusive probe is what reaches the model -----------------------
J=$(mktemp -d "$TMP/advise-amb.XXXXXX")
seat_home "$J" seat ambiguous
CB2=$(fake_curl "$J/c" 200 "$(answer seat_state pipeline_wait 0.95 '{"pipeline_wait":0.95,"true_wedge":0.03,"healthy_idle":0.02}')")
TB2=$(fake_tmux "$J/t" ambiguous sess:seat)
OUT=$(PATH="$TB2:$CB2:$BASE_PATH" TYPESAFE_API_KEY="$KEY" FM_HOME="$J" \
  FM_STATE_OVERRIDE="$J/state" "$ADVISE" seat 2>&1)
assert_contains "$OUT" 'probe: ambiguous' 'the inconclusive probe state is reported'
assert_contains "$OUT" 'advice: pipeline_wait' 'a confident model answer becomes the advice'
assert_contains "$OUT" 'source: model' 'the advice is attributed to the model'
assert_present "$J/c/log/argv" 'an inconclusive probe does reach the model'
# The request carries structured signals only, never the seat id or free text.
BODY=$(command cat "$J/c/log/body")
assert_contains "$BODY" 'endpoint_probe' 'the request carries the deterministic probe state'
assert_not_contains "$BODY" '"seat_id"' 'the request carries no seat id field'

# --- the advisor can never authorize a relaunch ----------------------------
K=$(mktemp -d "$TMP/advise-wedge.XXXXXX")
seat_home "$K" seat ambiguous
CB3=$(fake_curl "$K/c" 200 "$(answer seat_state true_wedge 0.99 '{"pipeline_wait":0.005,"true_wedge":0.99,"healthy_idle":0.005}')")
TB3=$(fake_tmux "$K/t" ambiguous sess:seat)
OUT=$(PATH="$TB3:$CB3:$BASE_PATH" TYPESAFE_API_KEY="$KEY" FM_HOME="$K" \
  FM_STATE_OVERRIDE="$K/state" "$ADVISE" seat 2>&1)
assert_contains "$OUT" 'advice: true_wedge' 'a wedge verdict is reported as the advice'
assert_contains "$OUT" 'probe: ambiguous' 'the probe state stays inconclusive beside a wedge verdict'
assert_contains "$OUT" 'authority: advisory only; never authorizes a relaunch' \
  'even a confident wedge verdict states that it grants no relaunch authority'
assert_not_contains "$OUT" 'probe: dead' 'the advisor never restates an inconclusive probe as dead'

# --- every failure of the advisor fails open toward leaving the seat alone ---
for body_code in '500' '000'; do
  L=$(mktemp -d "$TMP/advise-fail$body_code.XXXXXX")
  seat_home "$L" seat ambiguous
  CB4=$(fake_curl "$L/c" "$body_code" 'nope')
  TB4=$(fake_tmux "$L/t" ambiguous sess:seat)
  OUT=$(PATH="$TB4:$CB4:$BASE_PATH" TYPESAFE_API_KEY="$KEY" FM_HOME="$L" \
    FM_STATE_OVERRIDE="$L/state" "$ADVISE" seat 2>&1)
  expect_code 0 "$?" "an http $body_code failure still exits 0"
  assert_contains "$OUT" 'status: unavailable' "an http $body_code failure is unavailable"
  assert_contains "$OUT" 'advice: healthy_idle' "an http $body_code failure leaves the seat alone"
done

# A low-confidence wedge verdict is the dangerous one, and must not be taken.
M=$(mktemp -d "$TMP/advise-floor.XXXXXX")
seat_home "$M" seat ambiguous
CB5=$(fake_curl "$M/c" 200 "$(answer seat_state true_wedge 0.4 '{"pipeline_wait":0.3,"true_wedge":0.4,"healthy_idle":0.3}')")
TB5=$(fake_tmux "$M/t" ambiguous sess:seat)
OUT=$(PATH="$TB5:$CB5:$BASE_PATH" TYPESAFE_API_KEY="$KEY" FM_HOME="$M" \
  FM_STATE_OVERRIDE="$M/state" "$ADVISE" seat 2>&1)
assert_contains "$OUT" 'status: ambiguous' 'a below-floor answer is ambiguous'
assert_contains "$OUT" 'advice: healthy_idle' 'a below-floor wedge verdict is not taken'
assert_contains "$OUT" 'best: true_wedge' 'the unused answer is still reported as evidence'

# Off, for the advisor too.
N=$(mktemp -d "$TMP/advise-off.XXXXXX")
seat_home "$N" seat ambiguous
CB6=$(fake_curl "$N/c" 200 "$(answer seat_state true_wedge 0.99 '{"pipeline_wait":0.005,"true_wedge":0.99,"healthy_idle":0.005}')")
TB6=$(fake_tmux "$N/t" ambiguous sess:seat)
OUT=$(PATH="$TB6:$CB6:$BASE_PATH" FM_HOME="$N" FM_STATE_OVERRIDE="$N/state" "$ADVISE" seat 2>&1)
assert_contains "$OUT" 'seat-state-advise: off' 'the advisor names itself when off'
assert_contains "$OUT" 'advice: healthy_idle' 'the off path leaves the seat alone'
assert_absent "$N/c/log/argv" 'an absent key never calls curl for the advisor either'

# A seat with no record is a usage error, not a guess.
OUT=$(FM_HOME="$N" FM_STATE_OVERRIDE="$N/state" "$ADVISE" no-such-seat 2>&1)
expect_code 2 $? 'an unknown seat is a usage error'

# --- the family names its own members ---------------------------------------
MEMBERS=$(bash -c '. "$0"/bin/fm-jev-lib.sh; fm_jev_members' "$ROOT")
for m in dispatch-resolve alert-route seat-state-advise; do
  assert_contains "$MEMBERS" "$m" "the family names $m as a member"
done
while read -r _ path; do
  [ -n "$path" ] || continue
  assert_present "$ROOT/$path" "every named family member exists at $path"
done <<EOF
$MEMBERS
EOF

pass 'fm-jev-family: deterministic first, no call when off, key off argv, fail-open in each tool own safe direction, bounded calibration, and no relaunch authority'
