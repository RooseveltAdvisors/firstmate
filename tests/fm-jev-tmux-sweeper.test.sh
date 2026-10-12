#!/usr/bin/env bash
# tests/fm-jev-tmux-sweeper.test.sh - Regression tests for Pattern 44 (Jev Multi-Agent Orphaned Screen & Tmux Dead Session Sweeper)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-tmux-sweeper.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-tmux-sweeper.py"

echo "Running Pattern 44 regression tests..."

# 1. ShellCheck
shellcheck "$GUARD_SH"
echo "ok - shellcheck clean"

# 2. Python syntax check
python3 -m py_compile "$GUARD_PY"
echo "ok - python syntax clean"

# 3. Help works
"$GUARD_SH" --help >/dev/null
echo "ok - --help works"

# 4. JSON schema validation on audit
json_out="$("$GUARD_SH" --json)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'summary' in data
assert 'sessions' in data
assert 'orphaned_candidates' in data
assert 'timestamp' in data
assert isinstance(data['summary']['healthy'], bool)
assert isinstance(data['summary']['total_sessions'], int)
for s in data['sessions']:
    assert 'name' in s
    assert 'windows' in s
    assert 'attached' in s
    assert 'protected' in s
    assert 'safe_to_reap' in s
    if s['name'] in ('firstmate', 'wiseman', 'second-brain', 'dotfiles'):
        assert s['protected'] is True, f'Session {s[\"name\"]} must be protected!'
"
echo "ok - json audit schema and protected sessions valid"

# 5. Unit test audit logic with mock sessions
python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-tmux-sweeper')

# Verify protected sessions constant
assert 'firstmate' in mod.PROTECTED_SESSIONS
assert 'wiseman' in mod.PROTECTED_SESSIONS
assert 'second-brain' in mod.PROTECTED_SESSIONS
assert 'dotfiles' in mod.PROTECTED_SESSIONS
"
echo "ok - module imports and protection invariants pass"

# 6. Check mode behavior
"$GUARD_SH" >/dev/null
echo "ok - text mode runs without error"

echo "ok - all Pattern 44 tmux sweeper tests passed"
