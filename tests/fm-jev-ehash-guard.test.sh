#!/usr/bin/env bash
# tests/fm-jev-ehash-guard.test.sh - Regression tests for Pattern 166 (TCP Established Hash Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ehash-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ehash-guard.py"

echo "Running Pattern 166 regression tests..."

# 1. ShellCheck
shellcheck "$GUARD_SH"
echo "ok - shellcheck clean"

# 2. Python syntax check
python3 -m py_compile "$GUARD_PY"
echo "ok - python syntax clean"

# 3. Help works
"$GUARD_SH" --help >/dev/null
echo "ok - --help works"

# 4. JSON schema validation on host audit
json_out="$("$GUARD_SH" --json || true)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'timestamp' in data
assert 'summary' in data
assert 'sockstat' in data
assert 'sysctls' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_ehash_entries' in s
assert 'tcp_inuse' in s
assert 'hash_utilization_pct' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-ehash-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    sockstat_f = d / 'sockstat'
    ehash_f = d / 'tcp_ehash_entries'
    child_ehash_f = d / 'tcp_child_ehash_entries'

    sockstat_f.write_text('TCP: inuse 600 orphan 0 tw 200 alloc 620 mem 0\n')
    ehash_f.write_text('524288\n')
    child_ehash_f.write_text('0\n')

    # Case 1: Nominal
    res = mod.audit_ehash(
        sockstat_file=str(sockstat_f),
        ehash_entries_file=str(ehash_f),
        child_ehash_file=str(child_ehash_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_ehash_entries'] == 524288
    assert res['summary']['tcp_inuse'] == 600
    assert res['summary']['hash_utilization_pct'] == 0.1144

    # Case 2: High utilization -> WARNING
    sockstat_f.write_text('TCP: inuse 450000 orphan 0 tw 200 alloc 460000 mem 0\n')
    res2 = mod.audit_ehash(
        sockstat_file=str(sockstat_f),
        ehash_entries_file=str(ehash_f),
        child_ehash_file=str(child_ehash_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('High established hash table utilization' in iss for iss in res2['summary']['issues'])

    # Case 3: Very low ehash_entries -> WARNING
    ehash_f.write_text('512\n')
    sockstat_f.write_text('TCP: inuse 10 orphan 0 tw 2 alloc 15 mem 0\n')
    res3 = mod.audit_ehash(
        sockstat_file=str(sockstat_f),
        ehash_entries_file=str(ehash_f),
        child_ehash_file=str(child_ehash_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('Dangerously low tcp_ehash_entries' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 166 regression tests passed!"
