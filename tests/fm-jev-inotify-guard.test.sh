#!/usr/bin/env bash
# tests/fm-jev-inotify-guard.test.sh - Regression tests for Pattern 40
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-inotify-guard.sh"

echo "Running Pattern 40 regression tests..."

# 1. ShellCheck
shellcheck "$GUARD_SH"
echo "ok - shellcheck clean"

# 2. Help works
"$GUARD_SH" --help >/dev/null
echo "ok - --help works"

# 3. JSON format validation
json_out="$("$GUARD_SH" --json)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'summary' in data
assert 'top_consumers' in data
assert data['summary']['max_user_watches'] > 0
assert data['summary']['total_watches'] >= 0
assert isinstance(data['summary']['healthy'], bool)
"
echo "ok - json schema valid"

# 4. Check mode passes on healthy system
"$GUARD_SH" --check
echo "ok - --check passed cleanly"

# 5. Low warning threshold flags properly
if "$GUARD_SH" --warning-pct 0.0001 --check >/dev/null 2>&1; then
    echo "FAILED: low warning threshold should have exited non-zero"
    exit 1
else
    echo "ok - low warning threshold correctly flags non-zero exit"
fi

# 6. Top consumers properly formatted
top_consumers_len=$(echo "$json_out" | python3 -c "import json, sys; print(len(json.load(sys.stdin)['top_consumers']))")
if [ "$top_consumers_len" -ge 1 ]; then
    echo "ok - top consumers parsed ($top_consumers_len found)"
else
    echo "FAILED: expected at least 1 top consumer"
    exit 1
fi

echo "ok - all Pattern 40 inotify guard tests passed"
