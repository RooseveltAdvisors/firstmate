#!/usr/bin/env bash
# tests/fm-jev-window-shrink-guard.test.sh - Regression tests for Pattern 169 (TCP Window Shrink Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-window-shrink-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-window-shrink-guard.py"

echo "Running Pattern 169 regression tests..."

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
assert 'sysctls' in data
assert 'counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_shrink_window' in s
assert 'tcp_min_snd_mss' in s
assert 'rfc793_compliant' in s
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
mod = import_module('fm-jev-window-shrink-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    shrink_f = d / 'tcp_shrink_window'
    signed_f = d / 'tcp_workaround_signed_windows'
    mss_f = d / 'tcp_min_snd_mss'
    netstat_f = d / 'netstat'

    shrink_f.write_text('0\n')
    signed_f.write_text('0\n')
    mss_f.write_text('48\n')
    netstat_f.write_text('''TcpExt: BeyondWindow OutOfWindowIcmps
TcpExt: 1000 0
''')

    # Case 1: Nominal
    res = mod.audit_window_shrink(
        shrink_window_file=str(shrink_f),
        signed_windows_file=str(signed_f),
        min_snd_mss_file=str(mss_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_shrink_window'] == 0
    assert res['summary']['tcp_min_snd_mss'] == 48
    assert res['summary']['rfc793_compliant'] is True

    # Case 2: tcp_shrink_window == 1 -> WARNING
    shrink_f.write_text('1\n')
    res2 = mod.audit_window_shrink(
        shrink_window_file=str(shrink_f),
        signed_windows_file=str(signed_f),
        min_snd_mss_file=str(mss_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('violating strict RFC 793' in iss for iss in res2['summary']['issues'])

    # Case 3: Dangerously low min_snd_mss -> WARNING
    shrink_f.write_text('0\n')
    mss_f.write_text('16\n')
    res3 = mod.audit_window_shrink(
        shrink_window_file=str(shrink_f),
        signed_windows_file=str(signed_f),
        min_snd_mss_file=str(mss_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('Dangerously low tcp_min_snd_mss' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 169 regression tests passed!"
