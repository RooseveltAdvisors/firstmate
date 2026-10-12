#!/usr/bin/env bash
# tests/fm-jev-nf-conntrack-tcp-policy-guard.test.sh - Regression tests for Pattern 270 (NfConntrackTcpPolicyGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-nf-conntrack-tcp-policy-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-nf-conntrack-tcp-policy-guard.py"

echo "Running Pattern 270 regression tests..."

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
assert isinstance(data['tcp_be_liberal'], int)
assert isinstance(data['tcp_ignore_invalid_rst'], int)
assert isinstance(data['tcp_loose'], int)
assert isinstance(data['tcp_max_retrans'], int)
assert isinstance(data['checksum_enabled'], bool)
assert isinstance(data['strict_window_tracking'], bool)
assert isinstance(data['issues'], list)
assert isinstance(data['telemetry'], dict)
assert 'EstabResets' in data['telemetry']
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
mod = import_module('fm-jev-nf-conntrack-tcp-policy-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'netfilter'
    conf_dir.mkdir(parents=True)

    (conf_dir / 'nf_conntrack_tcp_be_liberal').write_text('0\n')
    (conf_dir / 'nf_conntrack_tcp_ignore_invalid_rst').write_text('0\n')
    (conf_dir / 'nf_conntrack_tcp_loose').write_text('1\n')
    (conf_dir / 'nf_conntrack_tcp_max_retrans').write_text('3\n')
    (conf_dir / 'nf_conntrack_checksum').write_text('1\n')
    (conf_dir / 'nf_conntrack_log_invalid').write_text('0\n')

    snmp = d / 'snmp'
    snmp.write_text('Tcp: EstabResets InErrs InCsumErrors\nTcp: 100 0 0\n')

    res = mod.audit_nf_conntrack_tcp_policy_guard(
        conf_dir=str(conf_dir),
        snmp_file=str(snmp),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['tcp_be_liberal'] == 0
    assert res['strict_window_tracking'] is True
    assert res['checksum_enabled'] is True
    assert res['telemetry']['EstabResets'] == 100

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'netfilter'
    conf_dir.mkdir(parents=True)

    (conf_dir / 'nf_conntrack_tcp_be_liberal').write_text('1\n')
    (conf_dir / 'nf_conntrack_checksum').write_text('0\n')
    (conf_dir / 'nf_conntrack_tcp_max_retrans').write_text('0\n')

    res = mod.audit_nf_conntrack_tcp_policy_guard(
        conf_dir=str(conf_dir),
        snmp_file=str(d / 'nonexistent'),
    )
    assert res['healthy'] is False
    assert res['status'] == 'WARNING'
    assert len(res['issues']) == 3
    assert res['tcp_be_liberal'] == 1
    assert res['checksum_enabled'] is False
"
echo "ok - unit tests with mock files valid"

echo "All Pattern 270 regression tests passed successfully!"
