#!/usr/bin/env bash
# tests/fm-jev-port-guard.test.sh - Regression tests for Pattern 41
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-port-guard.sh"

echo "Running Pattern 41 regression tests..."

# 1. ShellCheck
shellcheck "$GUARD_SH"
echo "ok - shellcheck clean"

# 2. Help works
"$GUARD_SH" --help >/dev/null
echo "ok - --help works"

# 3. JSON schema validation
json_out="$("$GUARD_SH" --json)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'summary' in data
assert 'state_distribution' in data
assert data['summary']['total_ephemeral_capacity'] > 0
assert data['summary']['saturation_pct'] >= 0.0
assert isinstance(data['summary']['healthy'], bool)
assert 'TIME_WAIT' in data['state_distribution']
assert 'ESTABLISHED' in data['state_distribution']
"
echo "ok - json schema valid"

# 4. Check mode passes cleanly on healthy host
"$GUARD_SH" --check
echo "ok - --check passed cleanly"

# 5. Low threshold flags properly
if "$GUARD_SH" --warning-timewait 1 --check >/dev/null 2>&1; then
    echo "FAILED: low warning-timewait should have exited non-zero"
    exit 1
else
    echo "ok - low warning-timewait correctly flags non-zero exit"
fi

# 6. State distribution matches expected keys
state_keys_len=$(echo "$json_out" | python3 -c "import json, sys; print(len(json.load(sys.stdin)['state_distribution']))")
if [ "$state_keys_len" -ge 10 ]; then
    echo "ok - state distribution has full TCP states ($state_keys_len states)"
else
    echo "FAILED: expected >= 10 TCP states in distribution"
    exit 1
fi

echo "ok - all Pattern 41 port guard tests passed"
