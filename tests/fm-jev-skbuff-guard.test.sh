#!/usr/bin/env bash
# tests/fm-jev-skbuff-guard.test.sh - Regression tests for Centennial Pattern 100 (Protocol Memory Pressure Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-skbuff-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-skbuff-guard.py"

echo "Running Pattern 100 regression tests..."

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
assert 'active_protocols' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'total_sockets' in s
assert 'active_protocol_count' in s
assert 'pressured_protocols' in s
for p in data['active_protocols']:
    assert 'protocol' in p
    assert 'sockets' in p
    assert 'memory_pages' in p
    assert 'memory_pressure' in p
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked protocols and mem files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-skbuff-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    proto_path = d / 'protocols'
    tcp_mem_path = d / 'tcp_mem'
    udp_mem_path = d / 'udp_mem'

    tcp_mem_path.write_text('10000 20000 30000\n')
    udp_mem_path.write_text('5000 10000 15000\n')

    mock_protocols_nominal = '''protocol  size sockets  memory press maxhdr  slab module     cl co di ac io in de sh ss gs se re bi br ha uh gp em
TCP       2560     100     500   no     320   yes  kernel      y  y  y  y  y  y  y  y  y  y  y  y  n  y  y  y  y  y
UDP       1408      20     100   NI       0   yes  kernel      y  y  y  n  y  y  y  n  y  y  y  y  n  n  y  y  y  n
UNIX-STREAM 1152   300      -1   NI       0   yes  kernel      y  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n
'''
    proto_path.write_text(mock_protocols_nominal)

    # Case 1: Healthy configuration and low memory usage
    res = mod.audit_protocol_memory(
        protocols_file=str(proto_path),
        tcp_mem_file=str(tcp_mem_path),
        udp_mem_file=str(udp_mem_path),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['total_sockets'] == 420
    assert len(res['summary']['pressured_protocols']) == 0
    assert res['summary']['tcp_memory_pages'] == 500

    # Case 2: Memory pressure asserted triggers warning
    mock_protocols_pressure = '''protocol  size sockets  memory press maxhdr  slab module     cl co di ac io in de sh ss gs se re bi br ha uh gp em
TCP       2560     500   28000  yes     320   yes  kernel      y  y  y  y  y  y  y  y  y  y  y  y  n  y  y  y  y  y
UDP       1408      20     100   NI       0   yes  kernel      y  y  y  n  y  y  y  n  y  y  y  y  n  n  y  y  y  n
'''
    proto_path.write_text(mock_protocols_pressure)
    res_press = mod.audit_protocol_memory(
        protocols_file=str(proto_path),
        tcp_mem_file=str(tcp_mem_path),
        udp_mem_file=str(udp_mem_path),
    )
    assert res_press['summary']['status'] == 'WARNING'
    assert 'TCP' in res_press['summary']['pressured_protocols']
    assert any('protocol memory pressure actively asserted' in iss for iss in res_press['summary']['issues'])
    assert any('High TCP buffer memory usage' in iss for iss in res_press['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 100 tests passed!"
