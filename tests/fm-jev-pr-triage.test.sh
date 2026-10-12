#!/usr/bin/env bash
# tests/fm-jev-pr-triage.test.sh - Test suite for Pattern 12 PR Triage Engine.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TRIAGE="$FM_ROOT/bin/fm-jev-pr-triage.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

printf '1. Verify help flag...\n'
"$TRIAGE" --help >/dev/null 2>&1 || fail "triage --help failed"
ok "help flag works"

printf '2. Verify check classification unit tests...\n'
python3 -c '
import importlib.util
spec = importlib.util.spec_from_file_location("fm_jev_pr_triage", "'"$FM_ROOT"'/bin/fm-jev-pr-triage.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
classify_checks = mod.classify_checks

# Test 1: In flight check
res1 = classify_checks([
    {"name": "CI/Test Suite (1/12)", "status": "COMPLETED", "conclusion": "SUCCESS"},
    {"name": "CI/Test Suite (2/12)", "status": "IN_PROGRESS", "conclusion": ""}
])
assert res1["verdict"] == "IN_FLIGHT"
assert res1["action"] == "WAIT_FOR_RUNNERS"
assert res1["counts"]["in_progress"] == 1

# Test 2: Blocked on bot gate
res2 = classify_checks([
    {"name": "CI/Test Suite (1/12)", "status": "COMPLETED", "conclusion": "SUCCESS"},
    {"name": "Require no-mistakes/PR review attestation", "status": "COMPLETED", "conclusion": "FAILURE"}
])
assert res2["verdict"] == "BLOCKED_ON_BOT_GATE"
assert res2["action"] == "DISPATCH_REVIEW_ATTESTATION"
assert res2["counts"]["bot_gates"] == 1

# Test 3: Real code regression
res3 = classify_checks([
    {"name": "CI/Test Suite (1/12)", "status": "COMPLETED", "conclusion": "FAILURE"},
    {"name": "Require no-mistakes/PR review attestation", "status": "COMPLETED", "conclusion": "SUCCESS"}
])
assert res3["verdict"] == "CODE_REGRESSION"
assert res3["action"] == "FIX_CODE_DEFECTS"
assert res3["counts"]["code_defects"] == 1

# Test 4: All green
res4 = classify_checks([
    {"name": "CI/Test Suite (1/12)", "status": "COMPLETED", "conclusion": "SUCCESS"},
    {"name": "Require no-mistakes/PR review attestation", "status": "COMPLETED", "conclusion": "SUCCESS"}
])
assert res4["verdict"] == "ALL_GREEN"
assert res4["action"] == "PROCEED_TO_MERGE"
' || fail "classification unit tests failed"
ok "check classification unit tests passed"

printf '3. Verify live triage on Portal PR #1780...\n'
out=$("$TRIAGE" --pr 1780 --repo ArcsHealth/Portal --json) || fail "live triage on PR 1780 failed"
echo "$out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert "pr" in data
assert "triage" in data
assert data["triage"]["counts"]["total"] >= 10
assert data["triage"]["verdict"] in ("IN_FLIGHT", "BLOCKED_ON_BOT_GATE", "CODE_REGRESSION", "ALL_GREEN")
' || fail "malformed triage JSON"
ok "live PR #1780 triaged successfully"

printf '4. Verify Markdown formatting...\n'
md_out=$("$TRIAGE" --pr 1780 --repo ArcsHealth/Portal --format markdown)
echo "$md_out" | grep -q "Jev PR Root-Cause Triage Report" || fail "missing header in markdown"
ok "markdown report format verified"

printf 'ok - all fm-jev-pr-triage tests passed\n'
