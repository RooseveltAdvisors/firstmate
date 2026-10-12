#!/usr/bin/env bash
# tests/fm-jev-tsq-pacing-guard.test.sh - Regression tests for Pattern 167 (TCP TSQ Pacing Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-tsq-pacing-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-tsq-pacing-guard.py"

echo "Running Pattern 167 regression tests..."

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
assert 'counters' in data
assert 'sysctls' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_limit_output_bytes' in s
assert 'tcp_pacing_ss_ratio' in s
assert 'tcp_pacing_ca_ratio' in s
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
mod = import_module('fm-jev-tsq-pacing-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    limit_f = d / 'tcp_limit_output_bytes'
    ss_f = d / 'tcp_pacing_ss_ratio'
    ca_f = d / 'tcp_pacing_ca_ratio'
    div_f = d / 'tcp_tso_win_divisor'
    min_f = d / 'tcp_min_tso_segs'
    netstat_f = d / 'netstat'

    limit_f.write_text('4194304\n')
    ss_f.write_text('200\n')
    ca_f.write_text('120\n')
    div_f.write_text('3\n')
    min_f.write_text('2\n')
    netstat_f.write_text('''TcpExt: TCPAutoCorking TCPSpuriousRtxHostQueues TCPDelivered
TcpExt: 7000000 300000 985000000
''')

    # Case 1: Nominal
    res = mod.audit_tsq_pacing(
        limit_output_bytes_file=str(limit_f),
        pacing_ss_file=str(ss_f),
        pacing_ca_file=str(ca_f),
        tso_win_divisor_file=str(div_f),
        min_tso_segs_file=str(min_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_limit_output_bytes'] == 4194304
    assert res['summary']['tcp_pacing_ss_ratio'] == 200
    assert res['summary']['tcp_pacing_ca_ratio'] == 120

    # Case 2: Very small limit -> WARNING
    limit_f.write_text('1024\n')
    res2 = mod.audit_tsq_pacing(
        limit_output_bytes_file=str(limit_f),
        pacing_ss_file=str(ss_f),
        pacing_ca_file=str(ca_f),
        tso_win_divisor_file=str(div_f),
        min_tso_segs_file=str(min_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('risk of TSQ pipeline starvation' in iss for iss in res2['summary']['issues'])

    # Case 3: Pacing CA ratio throttled < 100 -> WARNING
    limit_f.write_text('4194304\n')
    ca_f.write_text('80\n')
    res3 = mod.audit_tsq_pacing(
        limit_output_bytes_file=str(limit_f),
        pacing_ss_file=str(ss_f),
        pacing_ca_file=str(ca_f),
        tso_win_divisor_file=str(div_f),
        min_tso_segs_file=str(min_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('causing artificial throughput throttling' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 167 regression tests passed!"
