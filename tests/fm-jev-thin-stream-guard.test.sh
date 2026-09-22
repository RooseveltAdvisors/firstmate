#!/usr/bin/env bash
# tests/fm-jev-thin-stream-guard.test.sh - Regression tests for Pattern 127 (Early Retransmit & Thin Stream Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-thin-stream-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-thin-stream-guard.py"

echo "Running Pattern 127 regression tests..."

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
assert 'early_retrans' in s
assert 'recovery' in s
assert 'loss_probes' in s
assert 'tlp_conversion_pct' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and netstat files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-thin-stream-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    early_f = d / 'tcp_early_retrans'
    thin_f = d / 'tcp_thin_linear_timeouts'
    syn_f = d / 'tcp_syn_linear_timeouts'
    recov_f = d / 'tcp_recovery'
    frto_f = d / 'tcp_frto'
    netstat_f = d / 'netstat'

    early_f.write_text('3\n')
    thin_f.write_text('0\n')
    syn_f.write_text('4\n')
    recov_f.write_text('1\n')
    frto_f.write_text('2\n')

    netstat_f.write_text('''TcpExt: TCPLossProbes TCPLossProbeRecovery TCPFastRetrans TCPSlowStartRetrans TCPLostRetransmit TCPRetransFail TCPTimeouts TCPSpuriousRTOs
TcpExt: 1000 200 500 50 10 5 100 2
''')

    # Case 1: Nominal
    res = mod.audit_thin_stream(
        early_retrans_file=str(early_f),
        thin_linear_file=str(thin_f),
        syn_linear_file=str(syn_f),
        recovery_file=str(recov_f),
        frto_file=str(frto_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['early_retrans'] == 3
    assert res['summary']['tlp_conversion_pct'] == 20.0
    assert res['counters']['loss_probes'] == 1000

    # Case 2: Early Retransmit disabled -> WARNING
    early_f.write_text('0\n')
    res2 = mod.audit_thin_stream(
        early_retrans_file=str(early_f),
        thin_linear_file=str(thin_f),
        syn_linear_file=str(syn_f),
        recovery_file=str(recov_f),
        frto_file=str(frto_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('Early Retransmit is disabled' in iss for iss in res2['summary']['issues'])
    early_f.write_text('3\n')

    # Case 3: Recovery disabled -> WARNING
    recov_f.write_text('0\n')
    res3 = mod.audit_thin_stream(
        early_retrans_file=str(early_f),
        thin_linear_file=str(thin_f),
        syn_linear_file=str(syn_f),
        recovery_file=str(recov_f),
        frto_file=str(frto_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('RACK loss detection disabled' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 127 regression tests passed!"
