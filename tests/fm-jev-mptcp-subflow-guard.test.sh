#!/usr/bin/env bash
# tests/fm-jev-mptcp-subflow-guard.test.sh - Regression tests for Pattern 304 (MptcpSubflowGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-mptcp-subflow-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-mptcp-subflow-guard.py"

echo "Running Pattern 304 regression tests..."

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
assert data['pattern'] == 304
assert data['name'] == 'mptcp_subflow'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['mptcp_enabled'], int)
assert isinstance(data['path_manager'], str)
assert isinstance(data['available_path_managers'], list)
assert isinstance(data['scheduler'], str)
assert isinstance(data['available_schedulers'], list)
assert isinstance(data['stale_loss_cnt'], int)
assert isinstance(data['syn_retrans_before_tcp_fallback'], int)
assert isinstance(data['curr_estab'], int)
assert isinstance(data['subflow_stale'], int)
assert isinstance(data['subflow_recover'], int)
assert isinstance(data['fallback_failed'], int)
assert isinstance(data['dss_corruption_reset'], int)
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
mod = import_module('fm-jev-mptcp-subflow-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    (d / 'enabled').write_text('1\n')
    (d / 'path_manager').write_text('kernel\n')
    (d / 'available_path_managers').write_text('kernel userspace\n')
    (d / 'scheduler').write_text('default\n')
    (d / 'available_schedulers').write_text('default\n')
    (d / 'stale_loss_cnt').write_text('4\n')
    (d / 'syn_retrans_before_tcp_fallback').write_text('2\n')
    netstat_f = d / 'netstat'
    netstat_f.write_text('MPTcpExt: MPCurrEstab SubflowStale SubflowRecover FallbackFailed DSSCorruptionReset\nMPTcpExt: 0 0 0 0 0\n')

    res = mod.evaluate_mptcp_subflow(
        conf_dir=str(d),
        netstat_file=str(netstat_f),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['mptcp_enabled'] == 1
    assert res['path_manager'] == 'kernel'
    assert res['scheduler'] == 'default'
    assert res['stale_loss_cnt'] == 4
    assert res['syn_retrans_before_tcp_fallback'] == 2
    assert len(res['issues']) == 0

    # Test warnings & critical error
    (d / 'enabled').write_text('0\n')
    (d / 'path_manager').write_text('unknown_pm\n')
    (d / 'scheduler').write_text('unknown_sched\n')
    (d / 'stale_loss_cnt').write_text('25\n')
    (d / 'syn_retrans_before_tcp_fallback').write_text('15\n')
    netstat_f.write_text('MPTcpExt: MPCurrEstab SubflowStale SubflowRecover FallbackFailed DSSCorruptionReset\nMPTcpExt: 0 10 2 4 1\n')

    res_warn = mod.evaluate_mptcp_subflow(
        conf_dir=str(d),
        netstat_file=str(netstat_f),
    )
    assert res_warn['healthy'] is False
    assert res_warn['status'] == 'CRITICAL'
    assert any('MPTCP is disabled' in iss for iss in res_warn['issues'])
    assert any('unknown_pm' in iss for iss in res_warn['issues'])
    assert any('unknown_sched' in iss for iss in res_warn['issues'])
    assert any('stale_loss_cnt' in iss for iss in res_warn['issues'])
    assert any('syn_retrans_before_tcp_fallback' in iss for iss in res_warn['issues'])
    assert any('FallbackFailed=4' in iss for iss in res_warn['issues'])
    assert any('DSSCorruptionReset=1' in iss for iss in res_warn['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 304 regression tests passed successfully."
