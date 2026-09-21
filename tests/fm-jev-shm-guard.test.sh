#!/usr/bin/env bash
# tests/fm-jev-shm-guard.test.sh - Regression tests for Pattern 42
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-shm-guard.sh"

echo "Running Pattern 42 regression tests..."

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
assert 'candidates_sample' in data
assert data['summary']['shm_total_bytes'] > 0
assert data['summary']['usage_pct'] >= 0.0
assert isinstance(data['summary']['healthy'], bool)
"
echo "ok - json schema valid"

# 4. Check mode passes cleanly on healthy host
"$GUARD_SH" --check
echo "ok - --check passed cleanly"

# 5. Low warning threshold flags properly
if "$GUARD_SH" --warning-pct 0.000001 --check >/dev/null 2>&1; then
    echo "FAILED: low warning threshold should have exited non-zero"
    exit 1
else
    echo "ok - low warning threshold correctly flags non-zero exit"
fi

# 6. Safety invariant: open files marked safe_to_reclaim = False
python3 -c "
import json, sys
data = json.loads('''$json_out''')
for item in data['candidates_sample']:
    if item['is_open']:
        assert not item['safe_to_reclaim'], f'Open file {item[\"path\"]} must not be safe to reclaim'
"
echo "ok - safety invariant verified (open files protected from reclaim)"

echo "ok - all Pattern 42 POSIX shared memory guard tests passed"
