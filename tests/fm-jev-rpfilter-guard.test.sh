#!/usr/bin/env bash
# tests/fm-jev-rpfilter-guard.test.sh - Regression tests for Pattern 121 (IP Reverse Path Filtering Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-rpfilter-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-rpfilter-guard.py"

echo "Running Pattern 121 regression tests..."

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
assert 'interfaces' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'rp_filter_all' in s
assert 'rp_filter_default' in s
assert 'rp_drops' in s
assert 'interfaces_audited' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked conf directory and /proc/net/netstat files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-rpfilter-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_dir.mkdir()
    (conf_dir / 'all').mkdir()
    (conf_dir / 'default').mkdir()
    (conf_dir / 'eth0').mkdir()
    (conf_dir / 'lo').mkdir()

    (conf_dir / 'all' / 'rp_filter').write_text('2\n')
    (conf_dir / 'default' / 'rp_filter').write_text('2\n')
    (conf_dir / 'eth0' / 'rp_filter').write_text('2\n')
    (conf_dir / 'lo' / 'rp_filter').write_text('0\n')

    netstat_file = d / 'netstat'
    mock_netstat = '''TcpExt: IPReversePathFilter TCPTimeWaitOverflow
TcpExt: 0 0
'''
    netstat_file.write_text(mock_netstat)

    # Case 1: Nominal loose mode
    res = mod.audit_rpfilter(
        conf_dir=str(conf_dir),
        netstat_file=str(netstat_file),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['rp_filter_all'] == 2
    assert res['summary']['rp_drops'] == 0
    assert res['summary']['interfaces_audited'] == 4

    # Case 2: Disabled rp_filter warning
    (conf_dir / 'all' / 'rp_filter').write_text('0\n')
    res2 = mod.audit_rpfilter(
        conf_dir=str(conf_dir),
        netstat_file=str(netstat_file),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('rp_filter is disabled globally' in iss for iss in res2['summary']['issues'])
    (conf_dir / 'all' / 'rp_filter').write_text('2\n')

    # Case 3: Reverse path drops detected
    drop_netstat = mock_netstat.replace(' 0 0', ' 42 0')
    netstat_file.write_text(drop_netstat)
    res3 = mod.audit_rpfilter(
        conf_dir=str(conf_dir),
        netstat_file=str(netstat_file),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('Reverse path filtering drops detected' in iss for iss in res3['summary']['issues'])
    netstat_file.write_text(mock_netstat)

    # Case 4: Strict mode on eth0 advisory
    (conf_dir / 'eth0' / 'rp_filter').write_text('1\n')
    res4 = mod.audit_rpfilter(
        conf_dir=str(conf_dir),
        netstat_file=str(netstat_file),
    )
    assert any('Strict rp_filter (1) enabled on interfaces: eth0' in iss for iss in res4['summary']['issues'])
"
echo "ok - mocked conf and netstat unit tests pass"

echo "All Pattern 121 tests passed successfully!"
