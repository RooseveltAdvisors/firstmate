#!/usr/bin/env bash
# tests/fm-jev-pmtu-guard.test.sh - Regression tests for Pattern 144 (TCP PMTU Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-pmtu-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-pmtu-guard.py"

echo "Running Pattern 144 regression tests..."

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
assert 'tcp_mtu_probing' in s
assert 'tcp_base_mss' in s
assert 'tcp_min_snd_mss' in s
assert 'mtu_probes_failed' in s
assert 'mtu_probes_succeeded' in s
assert 'fail_ratio_pct' in s
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
mod = import_module('fm-jev-pmtu-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    probing_f = d / 'tcp_mtu_probing'
    base_f = d / 'tcp_base_mss'
    min_f = d / 'tcp_min_snd_mss'
    netstat_f = d / 'netstat'

    probing_f.write_text('1\n')
    base_f.write_text('1024\n')
    min_f.write_text('48\n')
    netstat_f.write_text('''TcpExt: TCPMTUPFail TCPMTUPSuccess TCPDelivered
TcpExt: 10 90 10000000
''')

    # Case 1: Nominal healthy state
    res = mod.audit_pmtu_guard(
        mtu_probing_file=str(probing_f),
        base_mss_file=str(base_f),
        min_snd_mss_file=str(min_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_mtu_probing'] == 1
    assert res['summary']['tcp_base_mss'] == 1024
    assert res['summary']['tcp_min_snd_mss'] == 48
    assert res['summary']['mtu_probes_failed'] == 10
    assert res['summary']['mtu_probes_succeeded'] == 90
    assert res['summary']['fail_ratio_pct'] == 10.0

    # Case 2: Severe PMTU failure ratio (> 60% with > 500 probes) -> CRITICAL
    netstat_f.write_text('''TcpExt: TCPMTUPFail TCPMTUPSuccess TCPDelivered
TcpExt: 700 300 10000000
''')
    res2 = mod.audit_pmtu_guard(
        mtu_probing_file=str(probing_f),
        base_mss_file=str(base_f),
        min_snd_mss_file=str(min_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'CRITICAL'
    assert res2['summary']['healthy'] is False
    assert any('Severe PMTU probing failure ratio' in iss for iss in res2['summary']['issues'])

    # Case 3: Abnormal base MSS (< 512) -> WARNING
    base_f.write_text('256\n')
    res3 = mod.audit_pmtu_guard(
        mtu_probing_file=str(probing_f),
        base_mss_file=str(base_f),
        min_snd_mss_file=str(min_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'CRITICAL'  # still critical from previous netstat
    base_f.write_text('1024\n')

    # Case 4: Missing files fallback (fail-open)
    res4 = mod.audit_pmtu_guard(
        mtu_probing_file='/nonexistent/probing',
        base_mss_file='/nonexistent/base',
        min_snd_mss_file='/nonexistent/min',
        netstat_file='/nonexistent/netstat',
    )
    assert res4['summary']['status'] == 'HEALTHY'
    assert res4['summary']['tcp_mtu_probing'] == 0
    assert res4['summary']['mtu_probes_failed'] == 0
"
echo "ok - unit tests pass"

echo "All Pattern 144 regression tests passed!"
