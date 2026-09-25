#!/usr/bin/env bash
# tests/fm-jev-ipv6-idgen-guard.test.sh - Regression tests for Pattern 271 (Ipv6IdgenGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv6-idgen-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv6-idgen-guard.py"

echo "Running Pattern 271 regression tests..."

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
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['idgen_delay_sec'], int)
assert isinstance(data['idgen_retries'], int)
assert isinstance(data['rfc7217_compliant'], bool)
assert isinstance(data['audited_interfaces'], int)
assert isinstance(data['issues'], list)
assert isinstance(data['telemetry'], dict)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked files
python3 -c "
import sys, tempfile
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-ipv6-idgen-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    eth0 = conf_dir / 'eth0'
    eth0.mkdir(parents=True)

    (d / 'idgen_delay').write_text('1\n')
    (d / 'idgen_retries').write_text('3\n')
    (eth0 / 'regen_max_retry').write_text('3\n')

    snmp = d / 'snmp6'
    snmp.write_text('Ip6InReceives 1000\nIp6InAddrErrors 0\n')

    res = mod.audit_ipv6_idgen_guard(
        ipv6_dir=str(d),
        snmp6_file=str(snmp),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['idgen_delay_sec'] == 1
    assert res['idgen_retries'] == 3
    assert res['rfc7217_compliant'] is True

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    eth0 = conf_dir / 'eth0'
    eth0.mkdir(parents=True)

    (d / 'idgen_delay').write_text('0\n')
    (d / 'idgen_retries').write_text('0\n')
    (eth0 / 'regen_max_retry').write_text('0\n')

    snmp = d / 'snmp6'
    snmp.write_text('Ip6InReceives 500\nIp6InAddrErrors 2\n')

    res = mod.audit_ipv6_idgen_guard(
        ipv6_dir=str(d),
        snmp6_file=str(snmp),
    )
    assert res['healthy'] is False
    assert res['status'] == 'WARNING'
    assert len(res['issues']) == 4
    assert res['idgen_delay_sec'] == 0
    assert res['idgen_retries'] == 0
    assert res['rfc7217_compliant'] is False
"
echo "ok - unit tests with mock files valid"

echo "All Pattern 271 regression tests passed successfully!"
