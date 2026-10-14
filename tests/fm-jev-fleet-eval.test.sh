#!/usr/bin/env bash
# tests/fm-jev-fleet-eval.test.sh - Verification suite for Pattern 7 Jev Fleet Evaluator.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVAL_BIN="$FM_ROOT/bin/fm-jev-fleet-eval.sh"

# The evaluator resolves its API key only from the live Jev install, so a host
# without one cannot exercise it; report that as a gate skip, not a failure.
ERR_OUT=$(mktemp)
trap 'rm -f "$ERR_OUT"' EXIT
JSON_RC=0
JSON_OUT=$("$EVAL_BIN" --json 2>"$ERR_OUT") || JSON_RC=$?
if [ "$JSON_RC" -ne 0 ] && grep -q 'TYPESAFE_API_KEY not available' "$ERR_OUT"; then
  echo "skip: live: TYPESAFE_API_KEY not available"
  exit 0
fi

echo "1. Verify --help output..."
"$EVAL_BIN" --help >/dev/null
echo "ok - help flags work"

echo "2. Verify --json output format..."
if [ "$JSON_RC" -ne 0 ]; then
  cat "$ERR_OUT" >&2
  echo "FAIL: --json exited $JSON_RC" >&2
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
