#!/usr/bin/env bash
# tests/fm-jev-notsent-guard.test.sh - Regression tests for Pattern 128 (TCP Unsent Queue Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-notsent-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-notsent-guard.py"

echo "Running Pattern 128 regression tests..."

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
assert 'tcp_notsent_lowat' in s
assert 'total_sockets' in s
assert 'total_tx_bytes' in s
assert 'bloated_sockets_count' in s
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
mod = import_module('fm-jev-notsent-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    notsent_f = d / 'tcp_notsent_lowat'
    autocork_f = d / 'tcp_autocorking'
    wmem_f = d / 'tcp_wmem'
    core_wmem_f = d / 'wmem_max'
    tcp_f = d / 'tcp'
    tcp6_f = d / 'tcp6'

    notsent_f.write_text('4294967295\n')
    autocork_f.write_text('1\n')
    wmem_f.write_text('4096 16384 4194304\n')
    core_wmem_f.write_text('212992\n')

    # Mock /proc/net/tcp with nominal queues
    tcp_f.write_text('''  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1388 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 12345 1 0000000000000000 100 0 0 10 0
   1: 0100007F:1389 0100007F:1388 01 00000100:00000000 00:00000000 00000000  1000        0 12346 1 0000000000000000 100 0 0 10 0
''')
    tcp6_f.write_text('''  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
''')

    # Case 1: Nominal
    res = mod.audit_notsent(
        notsent_lowat_file=str(notsent_f),
        autocorking_file=str(autocork_f),
        wmem_file=str(wmem_f),
        core_wmem_file=str(core_wmem_f),
        tcp_file=str(tcp_f),
        tcp6_file=str(tcp6_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['total_sockets'] == 2
    assert res['summary']['total_tx_bytes'] == 256  # 0x100 = 256 bytes
    assert res['summary']['bloated_sockets_count'] == 0

    # Case 2: Bloated socket (> 256 KiB in tx_queue) -> WARNING
    # 0x50000 = 327,680 bytes > 262,144 bytes
    tcp_f.write_text('''  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1389 0100007F:1388 01 00050000:00000000 00:00000000 00000000  1000        0 12346 1 0000000000000000 100 0 0 10 0
''')
    res2 = mod.audit_notsent(
        notsent_lowat_file=str(notsent_f),
        autocorking_file=str(autocork_f),
        wmem_file=str(wmem_f),
        core_wmem_file=str(core_wmem_f),
        tcp_file=str(tcp_f),
        tcp6_file=str(tcp6_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert res2['summary']['bloated_sockets_count'] == 1
    assert any('excessive write queue depth' in iss for iss in res2['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 128 regression tests passed!"
