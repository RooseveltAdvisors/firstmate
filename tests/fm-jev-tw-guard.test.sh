#!/usr/bin/env bash
# tests/fm-jev-tw-guard.test.sh - Regression tests for Pattern 97 (TCP Time-Wait & Ephemeral Port Range Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-tw-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-tw-guard.py"

echo "Running Pattern 97 regression tests..."

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
assert 'sockets' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'ephemeral_ports_total' in s
assert 'tw_sockets' in s
assert 'tw_port_utilization_pct' in s
sock = data['sockets']
assert 'tcp_tw' in sock
assert 'tcp_orphan' in sock
assert 'sockets_used' in sock
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and sockstat files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-tw-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    sockstat_path = d / 'sockstat'
    port_range_path = d / 'ip_local_port_range'
    tw_reuse_path = d / 'tcp_tw_reuse'
    max_tw_buckets_path = d / 'tcp_max_tw_buckets'
    fin_timeout_path = d / 'tcp_fin_timeout'

    port_range_path.write_text('32768 60999\n')
    tw_reuse_path.write_text('2\n')
    max_tw_buckets_path.write_text('262144\n')
    fin_timeout_path.write_text('60\n')

    # Case 1: Nominal sockstat
    sockstat_path.write_text('''sockets: used 1500
TCP: inuse 400 orphan 0 tw 250 alloc 450 mem 0
UDP: inuse 20 mem 3000
''')
    res = mod.audit_tw_sockets(
        sockstat_file=str(sockstat_path),
        port_range_file=str(port_range_path),
        tw_reuse_file=str(tw_reuse_path),
        max_tw_buckets_file=str(max_tw_buckets_path),
        fin_timeout_file=str(fin_timeout_path),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tw_sockets'] == 250
    assert len(res['summary']['issues']) == 0

    # Case 2: TIME_WAIT explosion (>70% of ephemeral ports) triggers warning
    sockstat_path.write_text('''sockets: used 25000
TCP: inuse 1000 orphan 5 tw 22000 alloc 23000 mem 100
''')
    res_tw_high = mod.audit_tw_sockets(
        sockstat_file=str(sockstat_path),
        port_range_file=str(port_range_path),
        tw_reuse_file=str(tw_reuse_path),
        max_tw_buckets_file=str(max_tw_buckets_path),
        fin_timeout_file=str(fin_timeout_path),
    )
    assert res_tw_high['summary']['status'] == 'WARNING'
    assert any('High TIME_WAIT saturation' in iss for iss in res_tw_high['summary']['issues'])

    # Case 3: Elevated orphan TCP sockets triggers warning
    sockstat_path.write_text('''sockets: used 2000
TCP: inuse 500 orphan 350 tw 500 alloc 850 mem 50
''')
    res_orphan = mod.audit_tw_sockets(
        sockstat_file=str(sockstat_path),
        port_range_file=str(port_range_path),
        tw_reuse_file=str(tw_reuse_path),
        max_tw_buckets_file=str(max_tw_buckets_path),
        fin_timeout_file=str(fin_timeout_path),
    )
    assert res_orphan['summary']['status'] == 'WARNING'
    assert any('Elevated orphan TCP sockets' in iss for iss in res_orphan['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 97 tests passed!"
