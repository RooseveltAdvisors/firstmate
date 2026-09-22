#!/usr/bin/env bash
# tests/fm-jev-segmentation-guard.test.sh - Regression tests for Pattern 141 (TCP Segmentation Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-segmentation-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-segmentation-guard.py"

echo "Running Pattern 141 regression tests..."

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
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'limit_output_bytes' in s
assert 'min_tso_segs' in s
assert 'tso_win_divisor' in s
assert 'default_qdisc' in s
assert 'spurious_host_queues' in s
assert 'spurious_ratio_pct' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and /proc/net/netstat files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-segmentation-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    limit_f = d / 'tcp_limit_output_bytes'
    min_tso_f = d / 'tcp_min_tso_segs'
    divisor_f = d / 'tcp_tso_win_divisor'
    qdisc_f = d / 'default_qdisc'
    netstat_f = d / 'netstat'

    limit_f.write_text('4194304\n')
    min_tso_f.write_text('2\n')
    divisor_f.write_text('3\n')
    qdisc_f.write_text('fq_codel\n')
    netstat_f.write_text('''TcpExt: TCPSpuriousRtxHostQueues TCPWqueueTooBig TCPAutoCorking TCPDelivered
TcpExt: 1000 0 50000 1000000
''')

    # Case 1: Nominal healthy state
    res = mod.audit_segmentation_guard(
        limit_output_bytes_file=str(limit_f),
        min_tso_segs_file=str(min_tso_f),
        tso_win_divisor_file=str(divisor_f),
        default_qdisc_file=str(qdisc_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['limit_output_bytes'] == 4194304
    assert res['summary']['limit_output_mb'] == 4.0
    assert res['summary']['min_tso_segs'] == 2
    assert res['summary']['tso_win_divisor'] == 3
    assert res['summary']['default_qdisc'] == 'fq_codel'
    assert res['summary']['spurious_host_queues'] == 1000
    assert res['summary']['spurious_ratio_pct'] == 0.1

    # Case 2: Excessively high limit output bytes (> 32MB) -> CRITICAL
    limit_f.write_text('67108864\n')  # 64MB
    res2 = mod.audit_segmentation_guard(
        limit_output_bytes_file=str(limit_f),
        min_tso_segs_file=str(min_tso_f),
        tso_win_divisor_file=str(divisor_f),
        default_qdisc_file=str(qdisc_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'CRITICAL'
    assert res2['summary']['healthy'] is False
    assert any('Excessively large TCP output pacing limit' in iss for iss in res2['summary']['issues'])
    limit_f.write_text('4194304\n')

    # Case 3: Invalid TSO window divisor (< 1) -> WARNING
    divisor_f.write_text('0\n')
    res3 = mod.audit_segmentation_guard(
        limit_output_bytes_file=str(limit_f),
        min_tso_segs_file=str(min_tso_f),
        tso_win_divisor_file=str(divisor_f),
        default_qdisc_file=str(qdisc_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('Invalid TSO window divisor' in iss for iss in res3['summary']['issues'])

    # Case 4: Missing files fallback (fail-open)
    res4 = mod.audit_segmentation_guard(
        limit_output_bytes_file='/nonexistent/limit',
        min_tso_segs_file='/nonexistent/min_tso',
        tso_win_divisor_file='/nonexistent/divisor',
        default_qdisc_file='/nonexistent/qdisc',
        netstat_file='/nonexistent/netstat',
    )
    assert res4['summary']['status'] == 'HEALTHY'
    assert res4['summary']['limit_output_bytes'] == 4194304
    assert res4['summary']['default_qdisc'] == 'fq_codel'
"
echo "ok - unit tests pass"

echo "All Pattern 141 regression tests passed!"
