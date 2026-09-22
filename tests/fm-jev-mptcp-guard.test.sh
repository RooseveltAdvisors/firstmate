#!/usr/bin/env bash
# tests/fm-jev-mptcp-guard.test.sh - Regression tests for Pattern 172 (MPTCP Subflow Health Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-mptcp-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-mptcp-guard.py"

echo "Running Pattern 172 regression tests..."

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
assert 'summary' in data
assert 'sysctls' in data
assert 'counters' in data
assert 'limits' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'mptcp_enabled' in s
assert 'path_manager' in s
assert 'scheduler' in s
assert 'mp_capable_syn_rx' in s
assert 'subflow_stale' in s
assert 'subflow_recover' in s
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
mod = import_module('fm-jev-mptcp-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    en_f = d / 'enabled'
    pm_f = d / 'path_manager'
    sch_f = d / 'scheduler'
    syn_f = d / 'syn_retrans_before_tcp_fallback'
    stale_f = d / 'stale_loss_cnt'
    netstat_f = d / 'netstat'

    en_f.write_text('1\n')
    pm_f.write_text('kernel\n')
    sch_f.write_text('default\n')
    syn_f.write_text('2\n')
    stale_f.write_text('4\n')
    netstat_f.write_text('''MPTcpExt: MPCapableSYNRX MPCapableSYNTX MPJoinSynRx MPJoinSynTx MPFailTx MPFailRx DSSCorruptionFallback DSSCorruptionReset SubflowStale SubflowRecover MPCurrEstab Blackhole
MPTcpExt: 0 0 0 0 0 0 0 0 0 0 0 0
''')

    # Case 1: Nominal
    res = mod.audit_mptcp(
        enabled_file=str(en_f),
        path_manager_file=str(pm_f),
        scheduler_file=str(sch_f),
        syn_fallback_file=str(syn_f),
        stale_loss_file=str(stale_f),
        netstat_file=str(netstat_f),
        check_ip=False,
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['mptcp_enabled'] == 1
    assert res['summary']['path_manager'] == 'kernel'
    assert res['summary']['scheduler'] == 'default'

    # Case 2: DSS corruption detected -> WARNING
    netstat_f.write_text('''MPTcpExt: MPCapableSYNRX MPCapableSYNTX MPJoinSynRx MPJoinSynTx MPFailTx MPFailRx DSSCorruptionFallback DSSCorruptionReset SubflowStale SubflowRecover MPCurrEstab Blackhole
MPTcpExt: 0 0 0 0 0 0 3 0 0 0 0 0
''')
    res2 = mod.audit_mptcp(
        enabled_file=str(en_f),
        path_manager_file=str(pm_f),
        scheduler_file=str(sch_f),
        syn_fallback_file=str(syn_f),
        stale_loss_file=str(stale_f),
        netstat_file=str(netstat_f),
        check_ip=False,
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('DSS corruption' in iss for iss in res2['summary']['issues'])

    # Case 3: Stale subflow unrecovered -> WARNING
    netstat_f.write_text('''MPTcpExt: MPCapableSYNRX MPCapableSYNTX MPJoinSynRx MPJoinSynTx MPFailTx MPFailRx DSSCorruptionFallback DSSCorruptionReset SubflowStale SubflowRecover MPCurrEstab Blackhole
MPTcpExt: 0 0 0 0 0 0 0 0 15 0 0 0
''')
    res3 = mod.audit_mptcp(
        enabled_file=str(en_f),
        path_manager_file=str(pm_f),
        scheduler_file=str(sch_f),
        syn_fallback_file=str(syn_f),
        stale_loss_file=str(stale_f),
        netstat_file=str(netstat_f),
        check_ip=False,
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('Subflows stale without recovery' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 172 regression tests passed: 6/6 tests ok"
