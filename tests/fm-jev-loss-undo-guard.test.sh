#!/usr/bin/env bash
# tests/fm-jev-loss-undo-guard.test.sh - Regression tests for Pattern 144 (TCP Loss Undo Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-loss-undo-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-loss-undo-guard.py"

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
assert 'total_undos' in s
assert 'undo_ratio_pct' in s
assert 'lost_retrans' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked /proc/net/netstat files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-loss-undo-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    netstat_f = d / 'netstat'

    netstat_f.write_text('''TcpExt: TCPFullUndo TCPPartialUndo TCPDSACKUndo TCPLossUndo TCPLostRetransmit TCPFastRetrans TCPSlowStartRetrans TCPTimeouts
TcpExt: 100 20 200 50 100 2000 10 500
''')

    # Case 1: Nominal (370 undos / 2000 fast retrans = 18.5%)
    res = mod.audit_loss_undo(netstat_file=str(netstat_f))
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['total_undos'] == 370
    assert res['summary']['undo_ratio_pct'] == 18.5
    assert res['summary']['lost_retrans'] == 100

    # Case 2: Excessive undo ratio (> 50%) -> WARNING
    netstat_f.write_text('''TcpExt: TCPFullUndo TCPPartialUndo TCPDSACKUndo TCPLossUndo TCPLostRetransmit TCPFastRetrans TCPSlowStartRetrans TCPTimeouts
TcpExt: 600 200 400 100 100 2000 10 500
''')
    res2 = mod.audit_loss_undo(netstat_file=str(netstat_f))
    assert res2['summary']['status'] == 'WARNING'
    assert any('High CWND undo ratio' in iss for iss in res2['summary']['issues'])

    # Case 3: Severe lost retransmissions (> 150% of fast rtx) -> WARNING
    netstat_f.write_text('''TcpExt: TCPFullUndo TCPPartialUndo TCPDSACKUndo TCPLossUndo TCPLostRetransmit TCPFastRetrans TCPSlowStartRetrans TCPTimeouts
TcpExt: 100 20 200 50 4000 2000 10 500
''')
    res3 = mod.audit_loss_undo(netstat_file=str(netstat_f))
    assert res3['summary']['status'] == 'WARNING'
    assert any('Severe retransmission loss' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 144 regression tests passed!"
