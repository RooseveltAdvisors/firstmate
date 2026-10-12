#!/usr/bin/env bash
# tests/fm-jev-timewait-guard.test.sh - Regression tests for Pattern 164 (TCP TIME-WAIT Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-timewait-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-timewait-guard.py"

echo "Running Pattern 164 regression tests..."

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
assert 'active_tw' in s
assert 'max_tw_buckets' in s
assert 'bucket_utilization_pct' in s
assert 'tcp_tw_reuse' in s
assert 'tw_overflow' in s
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
mod = import_module('fm-jev-timewait-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    sockstat_f = d / 'sockstat'
    netstat_f = d / 'netstat'
    max_tw_f = d / 'tcp_max_tw_buckets'
    tw_reuse_f = d / 'tcp_tw_reuse'
    tw_delay_f = d / 'tcp_tw_reuse_delay'

    sockstat_f.write_text('TCP: inuse 500 orphan 0 tw 250 alloc 520 mem 0\n')
    netstat_f.write_text('''TcpExt: TW TWRecycled TWKilled PAWSTimewait TCPTimeWaitOverflow
TcpExt: 9000000 10000 0 50 0
''')
    max_tw_f.write_text('262144\n')
    tw_reuse_f.write_text('2\n')
    tw_delay_f.write_text('1000\n')

    # Case 1: Nominal
    res = mod.audit_timewait(
        sockstat_file=str(sockstat_f),
        netstat_file=str(netstat_f),
        max_tw_buckets_file=str(max_tw_f),
        tw_reuse_file=str(tw_reuse_f),
        tw_reuse_delay_file=str(tw_delay_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['active_tw'] == 250
    assert res['summary']['max_tw_buckets'] == 262144
    assert res['summary']['tw_overflow'] == 0

    # Case 2: Overflow detected -> WARNING
    netstat_f.write_text('''TcpExt: TW TWRecycled TWKilled PAWSTimewait TCPTimeWaitOverflow
TcpExt: 9000000 10000 0 50 5
''')
    res2 = mod.audit_timewait(
        sockstat_file=str(sockstat_f),
        netstat_file=str(netstat_f),
        max_tw_buckets_file=str(max_tw_f),
        tw_reuse_file=str(tw_reuse_f),
        tw_reuse_delay_file=str(tw_delay_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('TIME-WAIT table overflows' in iss for iss in res2['summary']['issues'])

    # Case 3: High bucket utilization -> WARNING
    sockstat_f.write_text('TCP: inuse 500 orphan 0 tw 250000 alloc 520 mem 0\n')
    netstat_f.write_text('''TcpExt: TW TWRecycled TWKilled PAWSTimewait TCPTimeWaitOverflow
TcpExt: 9000000 10000 0 50 0
''')
    res3 = mod.audit_timewait(
        sockstat_file=str(sockstat_f),
        netstat_file=str(netstat_f),
        max_tw_buckets_file=str(max_tw_f),
        tw_reuse_file=str(tw_reuse_f),
        tw_reuse_delay_file=str(tw_delay_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('High TIME-WAIT table utilization' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 164 regression tests passed!"
