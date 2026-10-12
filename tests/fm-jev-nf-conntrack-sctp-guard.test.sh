#!/usr/bin/env bash
# tests/fm-jev-nf-conntrack-sctp-guard.test.sh - Regression tests for Pattern 278 (NfConntrackSctpGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-nf-conntrack-sctp-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-nf-conntrack-sctp-guard.py"

echo "Running Pattern 278 regression tests..."

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
assert isinstance(data['timeout_closed'], int)
assert isinstance(data['timeout_cookie_wait'], int)
assert isinstance(data['timeout_cookie_echoed'], int)
assert isinstance(data['timeout_established'], int)
assert isinstance(data['timeout_heartbeat_sent'], int)
assert isinstance(data['timeout_shutdown_sent'], int)
assert isinstance(data['timeout_shutdown_recd'], int)
assert isinstance(data['timeout_shutdown_ack_sent'], int)
assert isinstance(data['conntrack_count'], int)
assert isinstance(data['conntrack_max'], int)
assert isinstance(data['table_saturation_pct'], float)
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
mod = import_module('fm-jev-nf-conntrack-sctp-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    (d / 'nf_conntrack_sctp_timeout_closed').write_text('10\n')
    (d / 'nf_conntrack_sctp_timeout_cookie_wait').write_text('3\n')
    (d / 'nf_conntrack_sctp_timeout_cookie_echoed').write_text('3\n')
    (d / 'nf_conntrack_sctp_timeout_established').write_text('210\n')
    (d / 'nf_conntrack_sctp_timeout_heartbeat_sent').write_text('30\n')
    (d / 'nf_conntrack_sctp_timeout_shutdown_sent').write_text('3\n')
    (d / 'nf_conntrack_sctp_timeout_shutdown_recd').write_text('3\n')
    (d / 'nf_conntrack_sctp_timeout_shutdown_ack_sent').write_text('3\n')
    (d / 'nf_conntrack_count').write_text('1000\n')
    (d / 'nf_conntrack_max').write_text('262144\n')

    res = mod.audit_nf_conntrack_sctp_guard(conf_dir=str(d))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['timeout_closed'] == 10
    assert res['timeout_cookie_wait'] == 3
    assert res['timeout_established'] == 210

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    (d / 'nf_conntrack_sctp_timeout_closed').write_text('100\n')
    (d / 'nf_conntrack_sctp_timeout_cookie_wait').write_text('50\n')
    (d / 'nf_conntrack_sctp_timeout_cookie_echoed').write_text('50\n')
    (d / 'nf_conntrack_sctp_timeout_established').write_text('10\n')
    (d / 'nf_conntrack_sctp_timeout_heartbeat_sent').write_text('400\n')
    (d / 'nf_conntrack_sctp_timeout_shutdown_sent').write_text('80\n')
    (d / 'nf_conntrack_sctp_timeout_shutdown_recd').write_text('80\n')
    (d / 'nf_conntrack_sctp_timeout_shutdown_ack_sent').write_text('80\n')
    (d / 'nf_conntrack_count').write_text('250000\n')
    (d / 'nf_conntrack_max').write_text('262144\n')

    res = mod.audit_nf_conntrack_sctp_guard(conf_dir=str(d))
    assert res['healthy'] is False
    assert res['status'] == 'CRITICAL'
    assert any('Excessive SCTP CLOSED timeout' in iss for iss in res['issues'])
    assert any('Excessive SCTP COOKIE_WAIT timeout' in iss for iss in res['issues'])
    assert any('Excessive SCTP COOKIE_ECHOED timeout' in iss for iss in res['issues'])
    assert any('Abnormally low SCTP established timeout' in iss for iss in res['issues'])
    assert any('Excessive SCTP HEARTBEAT_SENT timeout' in iss for iss in res['issues'])
    assert any('Excessive SCTP SHUTDOWN_SENT timeout' in iss for iss in res['issues'])
    assert any('Critical conntrack table saturation' in iss for iss in res['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 278 regression tests passed!"
