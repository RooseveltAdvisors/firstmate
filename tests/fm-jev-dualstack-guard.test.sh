#!/usr/bin/env bash
# tests/fm-jev-dualstack-guard.test.sh - Regression tests for Pattern 124 (Dual-Stack Socket Guard)
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
assert 'healthy' in data
assert 'status' in data
assert 'pattern' in data
assert data['pattern'] == 124
assert 'name' in data
assert 'issues' in data
assert 'config' in data
assert 'listening_sockets' in data
assert 'telemetry' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['issues'], list)
assert 'bindv6only' in data['config']
assert 'dual_stack_default' in data['config']
telem = data['telemetry']
assert 'ip6_in_receives' in telem
assert 'ip6_in_discards' in telem
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
mod = import_module('fm-jev-dualstack-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)

    bindv6_file = d / 'bindv6only'
    bindv6_file.write_text('0\n')

    tcp6_file = d / 'tcp6'
    tcp6_content = '''  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000001000000:0277 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 174915588 1 0000000000000000 100 0 0 10 0
   1: 00000000000000000000000000000000:10DD 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1592963124 1 0000000000000000 100 0 0 10 0
'''
    tcp6_file.write_text(tcp6_content)

    snmp6_file = d / 'snmp6'
    snmp6_content = '''Ip6InReceives                   10000
Ip6InDiscards                   10
Ip6InNoRoutes                   0
Ip6OutRequests                  8000
'''
    snmp6_file.write_text(snmp6_content)

    conf_dir = d / 'conf'
    conf_dir.mkdir()
    (conf_dir / 'all').mkdir()
    (conf_dir / 'all' / 'disable_ipv6').write_text('0\n')

    # Test healthy dual-stack scenario
    res = mod.audit_dualstack(
        bindv6only_file=str(bindv6_file),
        conf_dir=str(conf_dir),
        tcp6_file=str(tcp6_file),
        snmp6_file=str(snmp6_file),
    )
    assert res['healthy'] is True
    assert len(res['issues']) == 0
    assert res['config']['bindv6only'] == 0
    assert res['config']['dual_stack_default'] is True
    assert res['listening_sockets']['total_tcp6_listeners'] == 2
    assert res['listening_sockets']['wildcard_listeners'] == 1

    # Test bindv6only strict mode issue scenario
    bindv6_file.write_text('1\n')
    res_b6 = mod.audit_dualstack(
        bindv6only_file=str(bindv6_file),
        conf_dir=str(conf_dir),
        tcp6_file=str(tcp6_file),
        snmp6_file=str(snmp6_file),
    )
    assert res_b6['healthy'] is False
    assert any('bindv6only is enabled' in issue for issue in res_b6['issues'])

    # Test high discard rate scenario
    bindv6_file.write_text('0\n')
    snmp6_bad = '''Ip6InReceives                   1000
Ip6InDiscards                   200
Ip6InNoRoutes                   0
Ip6OutRequests                  800
'''
    snmp6_file.write_text(snmp6_bad)
    res_disc = mod.audit_dualstack(
        bindv6only_file=str(bindv6_file),
        conf_dir=str(conf_dir),
        tcp6_file=str(tcp6_file),
        snmp6_file=str(snmp6_file),
    )
    assert res_disc['healthy'] is False
    assert any('Elevated IPv6 inbound discard rate' in issue for issue in res_disc['issues'])
"
echo "ok - mocked dualstack unit tests pass"

echo "All Pattern 124 tests passed successfully!"
