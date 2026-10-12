#!/usr/bin/env bash
# tests/fm-jev-dualstack-guard.test.sh - Regression tests for Pattern 124 (IPv4/IPv6 Dual-Stack Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-dualstack-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-dualstack-guard.py"

echo "Running Pattern 124 regression tests..."

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
assert 'counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'bindv6only' in s
assert 'disable_ipv6' in s
assert 'in_receives' in s
assert 'in_discards' in s
assert 'in_no_routes' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and /proc/net/snmp6 files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-dualstack-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    bindv6_file = d / 'bindv6only'
    disable_file = d / 'disable_ipv6'
    snmp6_file = d / 'snmp6'

    bindv6_file.write_text('0\n')
    disable_file.write_text('0\n')

    mock_snmp6 = '''Ip6InReceives 1000
Ip6InNoRoutes 0
Ip6InDiscards 10
Ip6OutDiscards 0
'''
    snmp6_file.write_text(mock_snmp6)

    # Case 1: Nominal
    res = mod.audit_dualstack(
        bindv6only_file=str(bindv6_file),
        disable_ipv6_file=str(disable_file),
        snmp6_file=str(snmp6_file),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['bindv6only'] == 0
    assert res['summary']['disable_ipv6'] == 0
    assert res['summary']['in_discards'] == 10

    # Case 2: Strict bindv6only warning
    bindv6_file.write_text('1\n')
    res2 = mod.audit_dualstack(
        bindv6only_file=str(bindv6_file),
        disable_ipv6_file=str(disable_file),
        snmp6_file=str(snmp6_file),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('bindv6only is enabled' in iss for iss in res2['summary']['issues'])
    bindv6_file.write_text('0\n')

    # Case 3: Elevated no-routes warning
    noroute_snmp6 = mock_snmp6.replace('Ip6InNoRoutes 0', 'Ip6InNoRoutes 2500')
    snmp6_file.write_text(noroute_snmp6)
    res3 = mod.audit_dualstack(
        bindv6only_file=str(bindv6_file),
        disable_ipv6_file=str(disable_file),
        snmp6_file=str(snmp6_file),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('Elevated IPv6 no-route discards' in iss for iss in res3['summary']['issues'])
"
echo "ok - mocked sysctl unit tests pass"

echo "All Pattern 124 tests passed successfully!"
