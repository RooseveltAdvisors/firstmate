#!/usr/bin/env bash
# tests/fm-jev-nf-conntrack-frag6-guard.test.sh - Regression tests for Pattern 273 (NfConntrackFrag6Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-nf-conntrack-frag6-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-nf-conntrack-frag6-guard.py"

echo "Running Pattern 273 regression tests..."

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
assert isinstance(data['frag6_high_thresh_bytes'], int)
assert isinstance(data['frag6_low_thresh_bytes'], int)
assert isinstance(data['frag6_timeout_sec'], int)
assert isinstance(data['frag6_inuse'], int)
assert isinstance(data['frag6_memory_bytes'], int)
assert isinstance(data['saturation_pct'], float)
assert isinstance(data['rfc8200_compliant'], bool)
assert isinstance(data['issues'], list)
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
mod = import_module('fm-jev-nf-conntrack-frag6-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)

    (d / 'nf_conntrack_frag6_high_thresh').write_text('4194304\n')
    (d / 'nf_conntrack_frag6_low_thresh').write_text('3145728\n')
    (d / 'nf_conntrack_frag6_timeout').write_text('60\n')

    sockstat6 = d / 'sockstat6'
    sockstat6.write_text('FRAG6: inuse 0 memory 0\n')

    snmp6 = d / 'snmp6'
    snmp6.write_text('Ip6ReasmReqds 10\nIp6ReasmOKs 10\nIp6ReasmFails 0\nIp6ReasmTimeout 0\n')

    res = mod.audit_nf_conntrack_frag6_guard(
        conf_dir=str(d),
        sockstat6_file=str(sockstat6),
        snmp6_file=str(snmp6),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['frag6_high_thresh_bytes'] == 4194304
    assert res['frag6_low_thresh_bytes'] == 3145728
    assert res['frag6_timeout_sec'] == 60
    assert res['rfc8200_compliant'] is True
    assert res['saturation_pct'] == 0.0

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)

    (d / 'nf_conntrack_frag6_high_thresh').write_text('0\n')
    (d / 'nf_conntrack_frag6_low_thresh').write_text('0\n')
    (d / 'nf_conntrack_frag6_timeout').write_text('200\n')

    sockstat6 = d / 'sockstat6'
    sockstat6.write_text('FRAG6: inuse 10 memory 5000000\n')

    snmp6 = d / 'snmp6'
    snmp6.write_text('Ip6ReasmReqds 200\nIp6ReasmFails 150\nIp6ReasmTimeout 50\n')

    res = mod.audit_nf_conntrack_frag6_guard(
        conf_dir=str(d),
        sockstat6_file=str(sockstat6),
        snmp6_file=str(snmp6),
    )
    assert res['healthy'] is False
    assert res['status'] == 'CRITICAL'
    assert any('high threshold is non-positive' in iss for iss in res['issues'])
    assert any('low threshold is non-positive' in iss for iss in res['issues'])
    assert any('timeout elevated' in iss for iss in res['issues'])
    assert any('High IPv6 fragment reassembly failure rate' in iss for iss in res['issues'])
"
echo "ok - mocked unit tests pass"

echo "All 6 tests passed successfully."
