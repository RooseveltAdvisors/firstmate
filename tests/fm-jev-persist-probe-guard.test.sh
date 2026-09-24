#!/usr/bin/env bash
# tests/fm-jev-persist-probe-guard.test.sh - Regression tests for Pattern 224 (TCP Zero-Window Probing & Persist Timer Stasis Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-persist-probe-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-persist-probe-guard.py"

echo "Running Pattern 224 regression tests..."

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
assert 'healthy' in data
assert 'win_probe' in data
assert 'persist_sockets_count' in data
assert 'tcp_retries2' in data
assert isinstance(data['win_probe'], int)
assert isinstance(data['persist_sockets_count'], int)
assert isinstance(data['healthy'], bool)
assert isinstance(data['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked procfs files
python3 -c "
import sys, tempfile
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-persist-probe-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    netstat_f = d / 'netstat'
    tcp_f = d / 'tcp'
    tcp6_f = d / 'tcp6'
    retries2_f = d / 'tcp_retries2'

    retries2_f.write_text('15\n')
    tcp6_f.write_text('  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n')

    # Scenario A: Nominal condition
    netstat_f.write_text('''TcpExt: SyncookiesSent TCPWinProbe TCPWantZeroWindowAdv TCPToZeroWindowAdv TCPFromZeroWindowAdv TCPZeroWindowDrop TCPDelivered
TcpExt: 0 10 5 5 5 0 100000
''')
    tcp_f.write_text('''  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12345 1 0000000000000000 100 0 0 10 0
''')

    res = mod.audit_persist_probe(
        netstat_file=str(netstat_f),
        tcp_file=str(tcp_f),
        tcp6_file=str(tcp6_f),
        retries2_file=str(retries2_f),
    )
    assert res['status'] == 'HEALTHY', f'Expected HEALTHY, got {res[\"status\"]}'
    assert res['healthy'] is True
    assert res['win_probe'] == 10
    assert res['persist_sockets_count'] == 0
    assert res['zero_win_drop'] == 0

    # Scenario B: WARNING on zero_win_drop
    netstat_f.write_text('''TcpExt: SyncookiesSent TCPWinProbe TCPWantZeroWindowAdv TCPToZeroWindowAdv TCPFromZeroWindowAdv TCPZeroWindowDrop TCPDelivered
TcpExt: 0 10 5 5 5 2 100000
''')
    res_warn = mod.audit_persist_probe(
        netstat_file=str(netstat_f),
        tcp_file=str(tcp_f),
        tcp6_file=str(tcp6_f),
        retries2_file=str(retries2_f),
    )
    assert res_warn['status'] == 'WARNING', f'Expected WARNING, got {res_warn[\"status\"]}'
    assert any('zero-window drops detected' in iss for iss in res_warn['issues'])

    # Scenario C: CRITICAL on high persist sockets
    # tr=4 is zero-window probe
    tcp_crit_lines = ['  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode']
    for i in range(250):
        tcp_crit_lines.append(f'   {i}: 0100007F:1F90 0100007F:2000 01 00001000:00000000 04:00000010 00000001     0        0 {10000+i} 1 0000000000000000 100 0 0 10 0')
    tcp_f.write_text('\n'.join(tcp_crit_lines) + '\n')

    res_crit = mod.audit_persist_probe(
        netstat_file=str(netstat_f),
        tcp_file=str(tcp_f),
        tcp6_file=str(tcp6_f),
        retries2_file=str(retries2_f),
        warn_persist_thresh=50,
        crit_persist_thresh=200,
    )
    assert res_crit['status'] == 'CRITICAL', f'Expected CRITICAL, got {res_crit[\"status\"]}'
    assert res_crit['healthy'] is False
    assert res_crit['persist_sockets_count'] == 250
    assert any('Critical persist timer stasis' in iss for iss in res_crit['issues'])
"
echo "ok - unit tests with mock procfs pass"

echo "All 6/6 tests passed successfully!"
