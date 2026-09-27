#!/usr/bin/env bash
# tests/fm-jev-alert-correlator.test.sh - verify Jev Alert Correlator & Pager Fatigue Dampening
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CORRELATOR_SH="$ROOT/bin/fm-jev-alert-correlator.sh"
CORRELATOR_PY="$ROOT/bin/fm-jev-alert-correlator.py"

[ -x "$CORRELATOR_SH" ] || fail "bin/fm-jev-alert-correlator.sh missing or not executable"
[ -x "$CORRELATOR_PY" ] || fail "bin/fm-jev-alert-correlator.py missing or not executable"

TDIR=$(fm_test_tmproot fm-jev-alert-test)
MOCK_STATE="$TDIR/state"
export FM_ALERT_CACHE_OVERRIDE="$TDIR/cache.json"
mkdir -p "$MOCK_STATE"

# Setup active hold for email ingest
cat > "$MOCK_STATE/captain-hold-email-ingest.status" <<'EOF'
state: on-hold · hold: email_ingest paused intentionally for privacy filter
EOF

# 1. Alert matching active hold is absorbed (exit 0)
out_hold=$(FM_STATE_OVERRIDE="$MOCK_STATE" "$CORRELATOR_SH" \
  --alert "stack-monitor critical: email_ingest heartbeat stale (age_ms=88354348)" 2>&1)
rc_hold=$?
[ "$rc_hold" -eq 0 ] || fail "alert matching hold was not absorbed (exit $rc_hold)"
assert_contains "$out_hold" "absorb [active_email_ingest_hold]" "detected hold match"

# 2. Truly novel alert is escalated (exit 2)
set +e
out_novel=$(FM_STATE_OVERRIDE="$MOCK_STATE" "$CORRELATOR_SH" \
  --alert "database deadlock detected on primary postgres cluster" 2>&1)
rc_novel=$?
set -e
[ "$rc_novel" -eq 2 ] || fail "novel alert was not escalated (exit $rc_novel)"
assert_contains "$out_novel" "escalate" "novel alert escalated"

# 3. Telemetry is written
[ -f "$MOCK_STATE/.jev-alert-telemetry" ] || fail "telemetry file was not created"
telem_content=$(cat "$MOCK_STATE/.jev-alert-telemetry")
assert_contains "$telem_content" "absorb" "telemetry contains absorb"
assert_contains "$telem_content" "escalate" "telemetry contains escalate"

# 4. Fingerprint dampening: the same condition with only counter changes must
#    absorb on the 3rd sighting inside the hour (raw-text hashing never matched).
set +e
r1=$(FM_STATE_OVERRIDE="$MOCK_STATE" "$CORRELATOR_SH" --alert "worker health critical: open=3 status=down" >/dev/null 2>&1; echo $?)
r2=$(FM_STATE_OVERRIDE="$MOCK_STATE" "$CORRELATOR_SH" --alert "worker health critical: open=7 status=down" >/dev/null 2>&1; echo $?)
r3=$(FM_STATE_OVERRIDE="$MOCK_STATE" "$CORRELATOR_SH" --alert "worker health critical: open=12 status=down" 2>&1; echo $?)
set -e
[ "$r1" -eq 2 ] || fail "first sighting should escalate (rc=$r1)"
# 2nd sighting: either Jev absorbs it semantically or it escalates again; both are valid.
{ [ "$r2" -eq 0 ] || [ "$r2" -eq 2 ]; } || fail "second sighting rc invalid ($r2)"
assert_contains "$r3" "absorb [repeat_fingerprint_dampened]" "third normalized repeat absorbed"
assert_contains "$(cat "$MOCK_STATE/.jev-alert-telemetry")" "repeat_fingerprint_dampened" "telemetry records fingerprint dampening"

pass "all fm-jev-alert-correlator tests passed"
