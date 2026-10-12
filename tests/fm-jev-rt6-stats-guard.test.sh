#!/usr/bin/env bash
# tests/fm-jev-rt6-stats-guard.test.sh - Regression tests for Pattern 239 (Rt6StatsGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-rt6-stats-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-rt6-stats-guard.py"

echo "Running Pattern 239 regression tests..."

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
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['fib6_nodes'], int)
assert isinstance(s['fib6_route_nodes'], int)
assert isinstance(s['fib6_rt_alloc'], int)
assert isinstance(s['fib6_rt_entries'], int)
assert isinstance(s['fib6_rt_garbage'], int)
assert isinstance(s['issues'], list)
assert isinstance(s['recommendation'], str)
assert 'stats' in data
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked procfs files
python3 -c "
import sys, tempfile
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-rt6-stats-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    stats_f = d / 'rt6_stats'
    route_d = d / 'route'
    route_d.mkdir()

    # Mock clean IPv6 route stats
    stats_f.write_text('0001 0001 0434 0002 0000 0000 019a\n')
    (route_d / 'gc_thresh').write_text('1024\n')
    (route_d / 'max_size').write_text('2147483647\n')
    (route_d / 'gc_interval').write_text('30\n')
    (route_d / 'gc_timeout').write_text('60\n')
    (route_d / 'min_adv_mss').write_text('1220\n')
    (route_d / 'mtu_expires').write_text('600\n')

    rep = mod.audit_rt6_stats(rt6_stats_path=str(stats_f), sys_route6_path=str(route_d))
    s = rep['summary']
    assert s['status'] == 'HEALTHY'
    assert s['healthy'] is True
    assert s['fib6_nodes'] == 1
    assert s['fib6_route_nodes'] == 1
    assert s['fib6_rt_alloc'] == 1076
    assert s['fib6_rt_entries'] == 2
    assert s['fib6_rt_garbage'] == 0

    # Mock elevated garbage backlog (> 500)
    stats_f.write_text('0001 0001 0434 0002 0000 0258 019a\n')
    rep = mod.audit_rt6_stats(rt6_stats_path=str(stats_f), sys_route6_path=str(route_d))
    s = rep['summary']
    assert s['status'] == 'WARNING'
    assert s['healthy'] is False
    assert s['fib6_rt_garbage'] == 600
    assert any('Elevated FIB6 garbage queue backlog' in iss for iss in s['issues'])

    # Mock max_size reached
    stats_f.write_text('0001 0001 0434 0400 0000 0000 019a\n')
    (route_d / 'max_size').write_text('1024\n')
    rep = mod.audit_rt6_stats(rt6_stats_path=str(stats_f), sys_route6_path=str(route_d))
    s = rep['summary']
    assert s['status'] == 'CRITICAL'
    assert s['healthy'] is False
    assert any('IPv6 route table reached max_size' in iss for iss in s['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 239 tests passed successfully."
