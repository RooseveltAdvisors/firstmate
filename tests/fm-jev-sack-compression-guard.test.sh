#!/usr/bin/env bash
# tests/fm-jev-sack-compression-guard.test.sh - Regression tests for Pattern 137 (TCP SACK Compression Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-sack-compression-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-sack-compression-guard.py"

echo "Running Pattern 137 regression tests..."

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
assert 'tcp_comp_sack_nr' in s
assert 'tcp_comp_sack_delay_ms' in s
assert 'ack_compressed' in s
assert 'delayed_acks' in s
assert 'compression_ratio_pct' in s
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
mod = import_module('fm-jev-sack-compression-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    nr_f = d / 'tcp_comp_sack_nr'
    delay_f = d / 'tcp_comp_sack_delay_ns'
    netstat_f = d / 'netstat'

    nr_f.write_text('44\n')
    delay_f.write_text('1000000\n')
    netstat_f.write_text('''TcpExt: TCPAckCompressed DelayedACKs DelayedACKLocked DelayedACKLost TCPDelivered
TcpExt: 50000 70000 10 7000 1000000
''')

    # Case 1: Nominal healthy state
    res = mod.audit_sack_compression(
        comp_sack_nr_file=str(nr_f),
        comp_sack_delay_file=str(delay_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_comp_sack_nr'] == 44
    assert res['summary']['tcp_comp_sack_delay_ms'] == 1.0
    assert res['summary']['ack_compressed'] == 50000
    assert res['summary']['compression_ratio_pct'] == 41.67
    assert res['summary']['delayed_loss_pct'] == 10.0

    # Case 2: SACK compression disabled -> WARNING
    nr_f.write_text('0\n')
    res2 = mod.audit_sack_compression(
        comp_sack_nr_file=str(nr_f),
        comp_sack_delay_file=str(delay_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert res2['summary']['healthy'] is False
    assert any('TCP SACK compression is disabled' in iss for iss in res2['summary']['issues'])
    nr_f.write_text('44\n')

    # Case 3: Excessively high SACK delay (> 10ms) -> WARNING
    delay_f.write_text('25000000\n')  # 25ms
    res3 = mod.audit_sack_compression(
        comp_sack_nr_file=str(nr_f),
        comp_sack_delay_file=str(delay_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('excessively high' in iss for iss in res3['summary']['issues'])
    delay_f.write_text('1000000\n')

    # Case 4: Missing files fallback (fail-open)
    res4 = mod.audit_sack_compression(
        comp_sack_nr_file='/nonexistent/nr',
        comp_sack_delay_file='/nonexistent/delay',
        netstat_file='/nonexistent/netstat',
    )
    assert res4['summary']['status'] == 'HEALTHY'
    assert res4['summary']['tcp_comp_sack_nr'] == 44
    assert res4['summary']['ack_compressed'] == 0
"
echo "ok - unit tests pass"

echo "All Pattern 137 regression tests passed!"
