#!/usr/bin/env bash
# tests/fm-jev-nf-conntrack-tcp-timeouts-guard.test.sh - Regression tests for Pattern 274 (NfConntrackTcpTimeoutsGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-nf-conntrack-tcp-timeouts-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-nf-conntrack-tcp-timeouts-guard.py"

echo "Running Pattern 274 regression tests..."

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
assert isinstance(data['timeout_established'], int)
assert isinstance(data['timeout_syn_sent'], int)
assert isinstance(data['timeout_syn_recv'], int)
assert isinstance(data['timeout_fin_wait'], int)
assert isinstance(data['timeout_close_wait'], int)
assert isinstance(data['timeout_time_wait'], int)
assert isinstance(data['conntrack_count'], int)
assert isinstance(data['conntrack_max'], int)
assert isinstance(data['table_saturation_pct'], float)
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
mod = import_module('fm-jev-nf-conntrack-tcp-timeouts-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)

    (d / 'nf_conntrack_tcp_timeout_syn_sent').write_text('120\n')
    (d / 'nf_conntrack_tcp_timeout_syn_recv').write_text('60\n')
    (d / 'nf_conntrack_tcp_timeout_established').write_text('432000\n')
    (d / 'nf_conntrack_tcp_timeout_fin_wait').write_text('120\n')
    (d / 'nf_conntrack_tcp_timeout_close_wait').write_text('60\n')
    (d / 'nf_conntrack_tcp_timeout_last_ack').write_text('30\n')
    (d / 'nf_conntrack_tcp_timeout_time_wait').write_text('120\n')
    (d / 'nf_conntrack_tcp_timeout_close').write_text('10\n')
    (d / 'nf_conntrack_tcp_timeout_max_retrans').write_text('300\n')
    (d / 'nf_conntrack_tcp_timeout_unacknowledged').write_text('300\n')
    (d / 'nf_conntrack_count').write_text('1000\n')
    (d / 'nf_conntrack_max').write_text('262144\n')

    res = mod.audit_nf_conntrack_tcp_timeouts_guard(conf_dir=str(d))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['timeout_established'] == 432000
    assert res['timeout_syn_sent'] == 120
    assert res['table_saturation_pct'] == 0.381

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)

    (d / 'nf_conntrack_tcp_timeout_syn_sent').write_text('500\n')
    (d / 'nf_conntrack_tcp_timeout_syn_recv').write_text('300\n')
    (d / 'nf_conntrack_tcp_timeout_established').write_text('600\n')
    (d / 'nf_conntrack_tcp_timeout_fin_wait').write_text('120\n')
    (d / 'nf_conntrack_tcp_timeout_close_wait').write_text('300\n')
    (d / 'nf_conntrack_tcp_timeout_last_ack').write_text('30\n')
    (d / 'nf_conntrack_tcp_timeout_time_wait').write_text('500\n')
    (d / 'nf_conntrack_tcp_timeout_close').write_text('10\n')
    (d / 'nf_conntrack_tcp_timeout_max_retrans').write_text('300\n')
    (d / 'nf_conntrack_tcp_timeout_unacknowledged').write_text('300\n')
    (d / 'nf_conntrack_count').write_text('250000\n')
    (d / 'nf_conntrack_max').write_text('262144\n')

    res = mod.audit_nf_conntrack_tcp_timeouts_guard(conf_dir=str(d))
    assert res['healthy'] is False
    assert res['status'] == 'CRITICAL'
    assert any('Excessive TCP SYN_SENT timeout' in iss for iss in res['issues'])
    assert any('Low TCP established timeout' in iss for iss in res['issues'])
    assert any('Critical conntrack table saturation' in iss for iss in res['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 274 regression tests passed!"
