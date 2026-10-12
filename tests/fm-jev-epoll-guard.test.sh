#!/usr/bin/env bash
# tests/fm-jev-epoll-guard.test.sh - Regression tests for Pattern 139 (TCP Epoll Wait Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-epoll-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-epoll-guard.py"

echo "Running Pattern 139 regression tests..."

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
assert 'top_consumers' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'max_user_watches' in s
assert 'total_epoll_instances' in s
assert 'total_epoll_watches' in s
assert 'watch_utilization_pct' in s
assert isinstance(data['top_consumers'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and /proc files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-epoll-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    max_w_f = d / 'max_user_watches'
    max_w_f.write_text('10000\n')

    proc_dir = d / 'proc'
    proc_dir.mkdir()

    # Create dummy PID 1234
    p1 = proc_dir / '1234'
    (p1 / 'fdinfo').mkdir(parents=True)
    (p1 / 'comm').write_text('test-worker\n')
    (p1 / 'cmdline').write_bytes(b'python3 test-worker.py\x00--port\x008080\x00')
    (p1 / 'fdinfo' / '3').write_text('''pos: 0
flags: 02
tfd: 5 events: 19 data: 5
tfd: 6 events: 19 data: 6
tfd: 7 events: 19 data: 7
''')

    # Case 1: Nominal healthy state (3 watches / 10000 = 0.03%)
    res = mod.audit_epoll(
        max_watches_file=str(max_w_f),
        proc_dir=str(proc_dir),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['max_user_watches'] == 10000
    assert res['summary']['total_epoll_instances'] == 1
    assert res['summary']['total_epoll_watches'] == 3
    assert res['summary']['watch_utilization_pct'] == 0.03
    assert len(res['top_consumers']) == 1
    assert res['top_consumers'][0]['pid'] == 1234
    assert 'test-worker' in res['top_consumers'][0]['cmdline']

    # Case 2: High watch saturation (> 80%) -> CRITICAL
    max_w_f.write_text('3\n')
    res2 = mod.audit_epoll(
        max_watches_file=str(max_w_f),
        proc_dir=str(proc_dir),
    )
    assert res2['summary']['status'] == 'CRITICAL'
    assert res2['summary']['healthy'] is False
    assert any('critically saturated' in iss for iss in res2['summary']['issues'])
    max_w_f.write_text('1000000\n')

    # Case 3: Runaway single process watches (> 50,000) -> WARNING
    runaway_lines = ['pos: 0\nflags: 02\n'] + [f'tfd: {i} events: 19 data: {i}\n' for i in range(50001)]
    (p1 / 'fdinfo' / '4').write_text(''.join(runaway_lines))
    res3 = mod.audit_epoll(
        max_watches_file=str(max_w_f),
        proc_dir=str(proc_dir),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('excessive epoll watches' in iss for iss in res3['summary']['issues'])

    # Case 4: Missing files fallback (fail-open)
    res4 = mod.audit_epoll(
        max_watches_file='/nonexistent/max',
        proc_dir='/nonexistent/proc',
    )
    assert res4['summary']['status'] == 'HEALTHY'
    assert res4['summary']['max_user_watches'] == 1048576
    assert res4['summary']['total_epoll_instances'] == 0
    assert res4['summary']['total_epoll_watches'] == 0
"
echo "ok - unit tests pass"

echo "All Pattern 139 regression tests passed!"
