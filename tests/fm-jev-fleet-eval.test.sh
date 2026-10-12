#!/usr/bin/env bash
# tests/fm-jev-fleet-eval.test.sh - Verification suite for Pattern 7 Jev Fleet Evaluator.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVAL_BIN="$FM_ROOT/bin/fm-jev-fleet-eval.sh"

echo "1. Verify --help output..."
"$EVAL_BIN" --help >/dev/null
echo "ok - help flags work"

echo "2. Verify --json output format..."
# The evaluator needs the Jev vault's TYPESAFE_API_KEY. Without it (CI has no
# vault) the contract is a named refusal, not output.
if JSON_OUT=$("$EVAL_BIN" --json 2>"${TMPDIR:-/tmp}/fm-jev-fleet-eval.$$.err"); then
  rc=0
else
  rc=$?
fi
err=$(cat "${TMPDIR:-/tmp}/fm-jev-fleet-eval.$$.err")
rm -f "${TMPDIR:-/tmp}/fm-jev-fleet-eval.$$.err"
if [ "$rc" -ne 0 ]; then
  case "$err" in
    *"TYPESAFE_API_KEY not available"*)
      [ "$rc" -eq 1 ] || { echo "FAIL: missing key should exit 1, got $rc" >&2; exit 1; }
      echo "ok - missing TYPESAFE_API_KEY is refused by name (live evaluation skipped)"
      echo "ok - all fm-jev-fleet-eval tests passed"
      exit 0
      ;;
  esac
  echo "FAIL: evaluator failed (exit $rc): $err" >&2
  exit 1
fi
if ! printf '%s\n' "$JSON_OUT" | grep -q '"fleet_health_score"'; then
  echo "FAIL: Expected fleet_health_score in JSON output" >&2
  exit 1
fi
if ! printf '%s\n' "$JSON_OUT" | grep -q '"primary_bottleneck"'; then
  echo "FAIL: Expected primary_bottleneck in JSON output" >&2
  exit 1
fi
echo "ok - live Jev evaluation JSON format verified"

echo "ok - all fm-jev-fleet-eval tests passed"
