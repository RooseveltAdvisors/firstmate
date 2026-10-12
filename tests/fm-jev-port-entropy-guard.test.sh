#!/usr/bin/env bash
# tests/fm-jev-port-entropy-guard.test.sh - Regression tests for Pattern 131 (TCP Port Entropy Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-port-entropy-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-port-entropy-guard.py"

echo "Running Pattern 131 regression tests..."

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
assert 'port_min' in s
assert 'port_max' in s
assert 'total_capacity' in s
assert 'active_ephemeral_count' in s
assert 'distinct_destinations' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and /proc/net/tcp files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-port-entropy-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    range_f = d / 'ip_local_port_range'
    tcp_f = d / 'tcp'
    tcp6_f = d / 'tcp6'

    range_f.write_text('32768 60999\n')

    # Mock /proc/net/tcp with 2 sockets
    # Port 0x8000 = 32768, 0x8001 = 32769
    tcp_f.write_text('''  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:8000 0200007F:01BB 01 00000000:00000000 00:00000000 00000000  1000        0 12345 1 0000000000000000 100 0 0 10 0
   1: 0100007F:8001 0200007F:01BB 01 00000000:00000000 00:00000000 00000000  1000        0 12346 1 0000000000000000 100 0 0 10 0
''')
    tcp6_f.write_text('''  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
''')

    # Case 1: Nominal
    res = mod.audit_port_entropy(
        port_range_file=str(range_f),
        tcp_file=str(tcp_f),
        tcp6_file=str(tcp6_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['active_ephemeral_count'] == 2
    assert res['summary']['total_capacity'] == 28232
    assert res['summary']['distinct_destinations'] == 1

    # Case 2: Restricted port range (< 10000) -> WARNING
    range_f.write_text('50000 55000\n')
    res2 = mod.audit_port_entropy(
        port_range_file=str(range_f),
        tcp_file=str(tcp_f),
        tcp6_file=str(tcp6_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('Restricted ephemeral port range' in iss for iss in res2['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 131 regression tests passed!"
