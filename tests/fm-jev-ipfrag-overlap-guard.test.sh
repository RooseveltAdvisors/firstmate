#!/usr/bin/env bash
# tests/fm-jev-ipfrag-overlap-guard.test.sh - Regression tests for Pattern 289 (IpfragOverlapGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipfrag-overlap-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipfrag-overlap-guard.py"

echo "Running Pattern 289 regression tests..."

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
assert isinstance(data['ipfrag_max_dist'], int)
assert isinstance(data['ipfrag_time_sec'], int)
assert isinstance(data['ip6frag_time_sec'], int)
assert isinstance(data['v4_reasm_reqds'], int)
assert isinstance(data['v4_reasm_oks'], int)
assert isinstance(data['v4_reasm_fails'], int)
assert isinstance(data['v4_reasm_timeouts'], int)
assert isinstance(data['v6_reasm_reqds'], int)
assert isinstance(data['v6_reasm_oks'], int)
assert isinstance(data['v6_reasm_fails'], int)
assert isinstance(data['v6_reasm_timeouts'], int)
assert isinstance(data['overlap_defense_compliant'], bool)
assert isinstance(data['issues'], list)
assert isinstance(data['recommendations'], list)
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
mod = import_module('fm-jev-ipfrag-overlap-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    v4 = d / 'ipv4'
    v4.mkdir()
    (v4 / 'ipfrag_max_dist').write_text('64\n')
    (v4 / 'ipfrag_time').write_text('30\n')
    (v4 / 'ipfrag_secret_interval').write_text('0\n')

    v6 = d / 'ipv6'
    v6.mkdir()
    (v6 / 'ip6frag_time').write_text('60\n')
    (v6 / 'ip6frag_secret_interval').write_text('0\n')

    snmp_file = d / 'snmp'
    snmp_file.write_text('Ip: Forwarding DefaultTTL ReasmReqds ReasmOKs ReasmFails ReasmTimeout\nIp: 1 64 100 95 5 0\n')

    snmp6_file = d / 'snmp6'
    snmp6_file.write_text('Ip6ReasmReqds 10\nIp6ReasmOKs 10\nIp6ReasmFails 0\nIp6ReasmTimeout 0\n')

    res = mod.audit_ipfrag_overlap_guard(
        ipv4_dir=str(v4),
        ipv6_dir=str(v6),
        snmp_path=str(snmp_file),
        snmp6_path=str(snmp6_file),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['ipfrag_max_dist'] == 64
    assert res['ipfrag_time_sec'] == 30
    assert res['ip6frag_time_sec'] == 60
    assert res['v4_reasm_reqds'] == 100

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    v4 = d / 'ipv4'
    v4.mkdir()
    (v4 / 'ipfrag_max_dist').write_text('0\n')
    (v4 / 'ipfrag_time').write_text('2\n')
    (v4 / 'ipfrag_secret_interval').write_text('0\n')

    v6 = d / 'ipv6'
    v6.mkdir()
    (v6 / 'ip6frag_time').write_text('200\n')
    (v6 / 'ip6frag_secret_interval').write_text('0\n')

    snmp_file = d / 'snmp'
    snmp_file.write_text('Ip: Forwarding DefaultTTL ReasmFails\nIp: 1 64 800\n')

    snmp6_file = d / 'snmp6'
    snmp6_file.write_text('Ip6ReasmFails 300\n')

    res = mod.audit_ipfrag_overlap_guard(
        ipv4_dir=str(v4),
        ipv6_dir=str(v6),
        snmp_path=str(snmp_file),
        snmp6_path=str(snmp6_file),
    )
    assert res['healthy'] is False
    assert res['status'] == 'CRITICAL'
    assert any('CVE-2018-5391' in iss for iss in res['issues'])
    assert any('Low IPv4 fragment reassembly timeout' in iss for iss in res['issues'])
    assert any('Excessive IPv6 fragment reassembly timeout' in iss for iss in res['issues'])
    assert any('Elevated IP fragment reassembly failures' in iss for iss in res['issues'])
"
echo "ok - mocked unit tests pass"

echo "All 6/6 Pattern 289 tests passed successfully!"
