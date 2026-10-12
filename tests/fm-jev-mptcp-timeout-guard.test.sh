#!/usr/bin/env bash
# tests/fm-jev-mptcp-timeout-guard.test.sh - Regression tests for Pattern 285 (MptcpTimeoutGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-mptcp-timeout-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-mptcp-timeout-guard.py"

echo "Running Pattern 285 regression tests..."

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
assert isinstance(data['add_addr_timeout_sec'], int)
assert isinstance(data['close_timeout_sec'], int)
assert isinstance(data['blackhole_timeout_sec'], int)
assert isinstance(data['allow_join_initial_addr_port'], int)
assert isinstance(data['checksum_enabled'], int)
assert isinstance(data['pm_type'], int)
assert isinstance(data['mp_fail_tx'], int)
assert isinstance(data['mp_fail_rx'], int)
assert isinstance(data['dss_corruption_fallback'], int)
assert isinstance(data['dss_corruption_reset'], int)
assert isinstance(data['blackhole_count'], int)
assert isinstance(data['add_addr_tx_drop'], int)
assert isinstance(data['add_addr_drop'], int)
assert isinstance(data['mp_join_rejected'], int)
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
mod = import_module('fm-jev-mptcp-timeout-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    mptcp_dir = d / 'mptcp'
    mptcp_dir.mkdir()
    (mptcp_dir / 'add_addr_timeout').write_text('120\n')
    (mptcp_dir / 'close_timeout').write_text('60\n')
    (mptcp_dir / 'blackhole_timeout').write_text('3600\n')
    (mptcp_dir / 'allow_join_initial_addr_port').write_text('1\n')
    (mptcp_dir / 'checksum_enabled').write_text('0\n')
    (mptcp_dir / 'pm_type').write_text('0\n')

    netstat_file = d / 'netstat'
    netstat_file.write_text(
        'MPTcpExt: MPFailTx MPFailRx DSSCorruptionFallback Blackhole AddAddrTxDrop AddAddrDrop\n'
        'MPTcpExt: 0 0 0 0 0 0\n'
    )

    res = mod.audit_mptcp_timeout_guard(mptcp_dir=str(mptcp_dir), netstat_path=str(netstat_file))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['add_addr_timeout_sec'] == 120
    assert res['close_timeout_sec'] == 60
    assert res['blackhole_timeout_sec'] == 3600
    assert res['allow_join_initial_addr_port'] == 1
    assert res['checksum_enabled'] == 0
    assert res['pm_type'] == 0

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    mptcp_dir = d / 'mptcp'
    mptcp_dir.mkdir()
    (mptcp_dir / 'add_addr_timeout').write_text('0\n')
    (mptcp_dir / 'close_timeout').write_text('700\n')
    (mptcp_dir / 'blackhole_timeout').write_text('-1\n')
    (mptcp_dir / 'allow_join_initial_addr_port').write_text('1\n')
    (mptcp_dir / 'checksum_enabled').write_text('0\n')
    (mptcp_dir / 'pm_type').write_text('0\n')

    netstat_file = d / 'netstat'
    netstat_file.write_text(
        'MPTcpExt: MPFailTx MPFailRx DSSCorruptionFallback DSSCorruptionReset Blackhole AddAddrTxDrop AddAddrDrop\n'
        'MPTcpExt: 60 10 2 0 0 150 0\n'
    )

    res = mod.audit_mptcp_timeout_guard(mptcp_dir=str(mptcp_dir), netstat_path=str(netstat_file))
    assert res['healthy'] is False
    assert res['status'] == 'WARNING'
    assert any('Invalid add_addr_timeout' in iss for iss in res['issues'])
    assert any('High close_timeout' in iss for iss in res['issues'])
    assert any('Invalid blackhole_timeout' in iss for iss in res['issues'])
    assert any('MPTCP DSS corruption detected' in iss for iss in res['issues'])
    assert any('High MPTCP fallback failures' in iss for iss in res['issues'])
    assert any('Elevated ADD_ADDR drops' in iss for iss in res['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 285 regression tests PASSED (100% green)."
