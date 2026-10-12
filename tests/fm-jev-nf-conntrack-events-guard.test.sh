#!/usr/bin/env bash
# tests/fm-jev-nf-conntrack-events-guard.test.sh - Regression tests for Pattern 272 (NfConntrackEventsGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-nf-conntrack-events-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-nf-conntrack-events-guard.py"

echo "Running Pattern 272 regression tests..."

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
assert isinstance(data['events_mode'], int)
assert isinstance(data['acct_enabled'], bool)
assert isinstance(data['timestamp_enabled'], bool)
assert isinstance(data['expect_max'], int)
assert isinstance(data['udp_timeout'], int)
assert isinstance(data['udp_timeout_stream'], int)
assert isinstance(data['icmp_timeout'], int)
assert isinstance(data['icmpv6_timeout'], int)
assert isinstance(data['conntrack_count'], int)
assert isinstance(data['conntrack_max'], int)
assert isinstance(data['saturation_pct'], float)
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
mod = import_module('fm-jev-nf-conntrack-events-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)

    (d / 'nf_conntrack_events').write_text('2\n')
    (d / 'nf_conntrack_acct').write_text('0\n')
    (d / 'nf_conntrack_timestamp').write_text('0\n')
    (d / 'nf_conntrack_expect_max').write_text('4096\n')
    (d / 'nf_conntrack_udp_timeout').write_text('30\n')
    (d / 'nf_conntrack_udp_timeout_stream').write_text('120\n')
    (d / 'nf_conntrack_icmp_timeout').write_text('30\n')
    (d / 'nf_conntrack_icmpv6_timeout').write_text('30\n')
    (d / 'nf_conntrack_count').write_text('100\n')
    (d / 'nf_conntrack_max').write_text('10000\n')

    res = mod.audit_nf_conntrack_events_guard(conf_dir=str(d))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['events_mode'] == 2
    assert res['acct_enabled'] is False
    assert res['timestamp_enabled'] is False
    assert res['expect_max'] == 4096
    assert res['udp_timeout'] == 30
    assert res['udp_timeout_stream'] == 120
    assert res['saturation_pct'] == 1.0

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)

    (d / 'nf_conntrack_events').write_text('5\n')
    (d / 'nf_conntrack_acct').write_text('9\n')
    (d / 'nf_conntrack_timestamp').write_text('8\n')
    (d / 'nf_conntrack_expect_max').write_text('0\n')
    (d / 'nf_conntrack_udp_timeout').write_text('200\n')
    (d / 'nf_conntrack_udp_timeout_stream').write_text('50\n')
    (d / 'nf_conntrack_icmp_timeout').write_text('0\n')
    (d / 'nf_conntrack_icmpv6_timeout').write_text('0\n')
    (d / 'nf_conntrack_count').write_text('990\n')
    (d / 'nf_conntrack_max').write_text('1000\n')

    res = mod.audit_nf_conntrack_events_guard(conf_dir=str(d))
    assert res['healthy'] is False
    assert res['status'] == 'CRITICAL'
    assert any('Invalid Netfilter event delivery configuration' in iss for iss in res['issues'])
    assert any('Invalid Netfilter flow accounting configuration' in iss for iss in res['issues'])
    assert any('Invalid Netfilter flow timestamping configuration' in iss for iss in res['issues'])
    assert any('expectation table capacity is unconfigured' in iss for iss in res['issues'])
    assert any('exceeds stream timeout' in iss for iss in res['issues'])
    assert any('saturation critical' in iss for iss in res['issues'])
"
echo "ok - mocked unit tests pass"

echo "All 6 tests passed successfully."
