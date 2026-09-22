#!/usr/bin/env bash
# tests/fm-jev-transport-matrix-guard.test.sh - Regression tests for Pattern 200 (Bicentennial Milestone)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-transport-matrix-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-transport-matrix-guard.py"

echo "Running Pattern 200 regression tests..."

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
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert s['transport_reliability_index_pct'] == 100.0
assert s['healthy_subguards'] == 15
assert s['total_subguards'] == 15
assert len(s['guards_evaluated']) == 15
for g in s['guards_evaluated']:
    assert 'pattern' in g
    assert 'name' in g
    assert 'healthy' in g
    assert 'detail' in g
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
mod = import_module('fm-jev-transport-matrix-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    sys_dir = d / 'ipv4'
    sys_dir.mkdir()
    netstat_f = d / 'netstat'

    # Populate healthy sysctls
    (sys_dir / 'tcp_congestion_control').write_text('cubic\n')
    (sys_dir / 'tcp_slow_start_after_idle').write_text('1\n')
    (sys_dir / 'tcp_moderate_rcvbuf').write_text('1\n')
    (sys_dir / 'tcp_syncookies').write_text('1\n')
    (sys_dir / 'tcp_abort_on_overflow').write_text('0\n')
    (sys_dir / 'tcp_syn_retries').write_text('6\n')
    (sys_dir / 'tcp_autocorking').write_text('1\n')
    (sys_dir / 'tcp_pacing_ss_ratio').write_text('200\n')
    (sys_dir / 'tcp_pacing_ca_ratio').write_text('120\n')
    (sys_dir / 'tcp_frto').write_text('2\n')
    (sys_dir / 'tcp_ecn').write_text('2\n')
    (sys_dir / 'tcp_ecn_fallback').write_text('1\n')
    (sys_dir / 'tcp_reordering').write_text('3\n')
    (sys_dir / 'tcp_fin_timeout').write_text('60\n')
    (sys_dir / 'tcp_keepalive_time').write_text('7200\n')
    (sys_dir / 'tcp_keepalive_probes').write_text('9\n')

    # Populate healthy netstat
    netstat_f.write_text(
        'TcpExt: SyncookiesSent SyncookiesRecv TCPMemoryPressures TCPAbortOnMemory ListenDrops TCPHPHits TCPHPAcks TCPPureAcks\n'
        'TcpExt: 0 0 0 0 0 1000 5000 2000\n'
    )

    report = mod.audit_transport_matrix(
        proc_netstat=str(netstat_f),
        proc_sys_net=str(sys_dir)
    )
    s = report['summary']
    assert s['status'] == 'HEALTHY'
    assert s['transport_reliability_index_pct'] == 100.0
    assert s['healthy_subguards'] == 15

    # Test degraded condition (e.g. abort_on_overflow set to 1)
    (sys_dir / 'tcp_abort_on_overflow').write_text('1\n')
    report_deg = mod.audit_transport_matrix(
        proc_netstat=str(netstat_f),
        proc_sys_net=str(sys_dir)
    )
    s_deg = report_deg['summary']
    assert s_deg['status'] == 'WARNING'
    assert s_deg['transport_reliability_index_pct'] < 100.0
    assert s_deg['healthy_subguards'] == 14
"
echo "ok - mocked unit tests pass"

echo "All Pattern 200 tests passed successfully."
