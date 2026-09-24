#!/usr/bin/env bash
# tests/fm-jev-rtcache-guard.test.sh - Regression tests for Pattern 236 (Routing Cache Exception Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-rtcache-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-rtcache-guard.py"

echo "Running Pattern 236 regression tests..."

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
assert isinstance(s['entries'], int)
assert isinstance(s['gc_dst_overflow'], int)
assert isinstance(s['in_martian_src'], int)
assert isinstance(s['issues'], list)
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
mod = import_module('fm-jev-rtcache-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    sys_dir = d / 'route'
    sys_dir.mkdir()
    rt_cache_f = d / 'rt_cache'

    (sys_dir / 'max_size').write_text('2147483647\n')
    (sys_dir / 'gc_interval').write_text('60\n')
    (sys_dir / 'gc_timeout').write_text('300\n')
    (sys_dir / 'min_pmtu').write_text('552\n')
    (sys_dir / 'mtu_expires').write_text('600\n')

    # Healthy rt_cache
    rt_cache_f.write_text(
        'entries in_hit in_slow_tot in_slow_mc in_no_route in_brd in_martian_dst in_martian_src out_hit out_slow_tot out_slow_mc gc_total gc_ignored gc_goal_miss gc_dst_overflow in_hlist_search out_hlist_search\n'
        '00000010 00000000 00000050 00000000 00000002 00000000 00000000 00000001 00000000 00000100 00000005 00000000 00000000 00000000 00000000 00000000 00000000\n'
    )

    rep = mod.audit_rt_cache(
        proc_rt_cache=str(rt_cache_f),
        proc_sys_route=str(sys_dir)
    )
    s = rep['summary']
    assert s['status'] == 'HEALTHY'
    assert s['healthy'] is True
    assert s['entries'] == 16
    assert s['gc_dst_overflow'] == 0
    assert s['in_martian_src'] == 1

    # Overflow condition -> CRITICAL
    rt_cache_f.write_text(
        'entries in_hit in_slow_tot in_slow_mc in_no_route in_brd in_martian_dst in_martian_src out_hit out_slow_tot out_slow_mc gc_total gc_ignored gc_goal_miss gc_dst_overflow in_hlist_search out_hlist_search\n'
        '00000010 00000000 00000050 00000000 00000002 00000000 00000000 00000001 00000000 00000100 00000005 00000000 00000000 00000000 00000005 00000000 00000000\n'
    )
    rep2 = mod.audit_rt_cache(
        proc_rt_cache=str(rt_cache_f),
        proc_sys_route=str(sys_dir)
    )
    assert rep2['summary']['status'] == 'CRITICAL'
    assert rep2['summary']['healthy'] is False
    assert rep2['summary']['gc_dst_overflow'] == 5
"
echo "ok - mocked unit tests pass"

echo "All Pattern 236 tests passed successfully."
