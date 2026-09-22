#!/usr/bin/env bash
# tests/fm-jev-quota-prober.test.sh - Regression test suite for Pattern 9 Quota Prober.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROBER="$FM_ROOT/bin/fm-jev-quota-prober.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-jev-quota-prober.XXXXXX")
FAKEBIN="$LAB/fakebin"

cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
cursor_remaining=50
cursor_runway=through_reset
cursor_stale=false
codex_remaining=50
codex_runway=through_reset
codex_model_remaining=50
codex_model_runway=through_reset
if [ "${CURSOR_EXHAUSTED:-0}" = 1 ]; then
  cursor_remaining=0
  cursor_runway=exhausted_now
fi
if [ "${CURSOR_STALE:-0}" = 1 ]; then
  cursor_stale=true
fi
if [ "${CURSOR_UNKNOWN_RUNWAY:-0}" = 1 ]; then
  cursor_runway=unknown
fi
if [ "${CODEX_EXHAUSTED:-0}" = 1 ]; then
  codex_remaining=0
  codex_runway=exhausted_now
fi
if [ "${CODEX_MODEL_EXHAUSTED:-0}" = 1 ]; then
  codex_model_remaining=0
  codex_model_runway=exhausted_now
fi
printf '{"schemaVersion":5,"providers":[{"provider":"cursor","state":{"status":"fresh","stale":%s},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":%s,"runway":{"status":"%s"}}]}},{"provider":"codex","state":{"status":"fresh","stale":false},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":%s,"runway":{"status":"%s"}},{"scope":"model:gpt-5.6-luna","status":"known","effectivePercentRemaining":%s,"runway":{"status":"%s"}}]}}]}\n' \
  "$cursor_stale" "$cursor_remaining" "$cursor_runway" "$codex_remaining" "$codex_runway" "$codex_model_remaining" "$codex_model_runway"
SH
chmod +x "$FAKEBIN/quota-axi"
export PATH="$FAKEBIN:$PATH"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

printf '1. Verify help flag...\n'
"$PROBER" --help >/dev/null 2>&1 || fail "prober --help failed"
ok "help flag works"

printf '2. Verify --check-all output...\n'
output=$("$PROBER" --check-all) || fail "check-all failed"
printf '%s\n' "$output" | grep -q "Fleet Pre-Flight Harness Runway" || fail "missing header in check-all"
printf '%s\n' "$output" | grep -q "cursor-grok-4.6-high.*forbidden" || fail "check-all did not reject Grok"
ok "check-all rejects forbidden Grok lane"

printf '3. Verify --json output format...\n'
json_out=$("$PROBER" --check-all --json) || fail "--check-all --json failed"
echo "$json_out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert isinstance(data, list)
assert len(data) >= 3
assert any(d["harness"] == "cursor" for d in data)
grok = next(d for d in data if "grok" in d["model"])
assert grok["healthy"] is False
assert grok["status"] == "forbidden"
assert all("grok" not in d["divert_model"] for d in data)
' || fail "malformed json output"
ok "json output format verified"

printf '4. Verify --auto-divert flag on exhausted harness...\n'
divert_out=$("$PROBER" --harness pi --model zai-general/glm-5.3-flash --auto-divert) || fail "auto-divert failed"
echo "$divert_out" | grep -q "harness=cursor model=composer-2.5" || fail "failed to divert dry zai bundle"
ok "auto-divert safely redirects to cursor Composer"

printf '5. Verify auto-divert never targets Grok...\n'
if printf '%s\n' "$divert_out" | grep -qi "grok"; then
  fail "auto-divert target must never contain grok"
fi
ok "auto-divert target excludes Grok"

printf '6. Verify exhausted diversion destination is refused...\n'
if divert_out=$(CURSOR_EXHAUSTED=1 "$PROBER" --harness pi --model zai-general/glm-5.3-flash --auto-divert); then
  fail "auto-divert accepted an exhausted destination"
fi
[ -z "$divert_out" ] || fail "exhausted destination emitted a launch profile"
ok "auto-divert refuses exhausted destination"

printf '7. Verify Codex quota semantics drive exhaustion...\n'
if codex_out=$(CODEX_MODEL_EXHAUSTED=1 "$PROBER" --harness codex --model gpt-5.6-luna --json); then
  fail "Codex semantic exhaustion reported healthy"
fi
printf '%s\n' "$codex_out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["healthy"] is False
assert data["status"] == "exhausted"
' || fail "Codex semantic exhaustion result was malformed"
ok "Codex quota semantics detect exhaustion"

printf '8. Verify direct Grok launch is forbidden...\n'
if grok_out=$("$PROBER" --harness cursor --model cursor-grok-4.6-high --json); then
  fail "direct Grok launch reported healthy"
fi
printf '%s\n' "$grok_out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["healthy"] is False
assert data["status"] == "forbidden"
' || fail "Grok prohibition result was malformed"
ok "direct Grok launch is forbidden"

printf '9. Verify stale destination evidence is refused...\n'
if divert_out=$(CURSOR_STALE=1 "$PROBER" --harness pi --model zai-general/glm-5.3-flash --auto-divert); then
  fail "auto-divert accepted stale destination evidence"
fi
[ -z "$divert_out" ] || fail "stale destination emitted a launch profile"
ok "auto-divert refuses stale destination evidence"

printf '10. Verify unknown destination runway is refused...\n'
if divert_out=$(CURSOR_UNKNOWN_RUNWAY=1 "$PROBER" --harness pi --model zai-general/glm-5.3-flash --auto-divert); then
  fail "auto-divert accepted unknown destination runway"
fi
[ -z "$divert_out" ] || fail "unknown destination runway emitted a launch profile"
ok "auto-divert refuses unknown destination runway"

printf 'ok - all fm-jev-quota-prober tests passed\n'
