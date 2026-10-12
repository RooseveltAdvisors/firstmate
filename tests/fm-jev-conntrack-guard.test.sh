#!/usr/bin/env bash
# tests/fm-jev-conntrack-guard.test.sh - Regression tests for Pattern 207 (Netfilter Conntrack & Routing Cache Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-conntrack-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-conntrack-guard.py"

echo "Running Pattern 207 regression tests..."

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
assert isinstance(s['conntrack_count'], int)
assert isinstance(s['conntrack_max'], int)
assert isinstance(s['conntrack_buckets'], int)
assert isinstance(s['saturation_ratio'], float)
assert isinstance(s['bucket_chain_ratio'], float)
assert isinstance(s['tcp_timeout_established_sec'], int)
assert isinstance(s['rt_cache_entries'], int)
assert isinstance(s['rt_in_no_route'], int)
assert isinstance(s['rt_gc_dst_overflow'], int)
assert isinstance(s['issues'], list)
assert isinstance(s['recommendation'], str)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysfs / procfs files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-conntrack-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    netfilter_dir = d / 'netfilter'
    netfilter_dir.mkdir()
    rt_f = d / 'rt_cache'

    (netfilter_dir / 'nf_conntrack_count').write_text('1200\n')
    (netfilter_dir / 'nf_conntrack_max').write_text('262144\n')
    (netfilter_dir / 'nf_conntrack_buckets').write_text('65536\n')
    (netfilter_dir / 'nf_conntrack_tcp_timeout_established').write_text('432000\n')
    (netfilter_dir / 'nf_conntrack_tcp_timeout_close_wait').write_text('60\n')
    (netfilter_dir / 'nf_conntrack_tcp_timeout_time_wait').write_text('120\n')

    rt_f.write_text(
        'entries  in_hit   in_slow_tot in_slow_mc in_no_route in_brd   in_martian_dst in_martian_src out_hit  out_slow_tot out_slow_mc gc_total gc_ignored gc_goal_miss gc_dst_overflow in_hlist_search out_hlist_search\n'
        '00000010 00000000 00000005    00000000   00000001    00000000 00000000       00000002       00000000 00000020     00000001    00000000 00000000   00000000     00000000        00000000        00000000\n'
    )

    rep = mod.audit_conntrack(proc_sys_netfilter=str(netfilter_dir), proc_rt_cache=str(rt_f))
    s = rep['summary']
    assert s['status'] == 'HEALTHY'
    assert s['healthy'] is True
    assert s['conntrack_count'] == 1200
    assert s['conntrack_max'] == 262144
    assert s['saturation_ratio'] < 0.01
    assert s['rt_in_no_route'] == 1
    assert s['rt_gc_dst_overflow'] == 0

    # Mock Critical condition (saturation >= 85%)
    (netfilter_dir / 'nf_conntrack_count').write_text('250000\n')
    rep_crit = mod.audit_conntrack(proc_sys_netfilter=str(netfilter_dir), proc_rt_cache=str(rt_f))
    assert rep_crit['summary']['status'] == 'CRITICAL'
    assert rep_crit['summary']['healthy'] is False
    assert any('critically saturated' in iss for iss in rep_crit['summary']['issues'])

    # Mock Critical routing cache overflow
    (netfilter_dir / 'nf_conntrack_count').write_text('1200\n')
    rt_f.write_text(
        'entries  in_hit   in_slow_tot in_slow_mc in_no_route in_brd   in_martian_dst in_martian_src out_hit  out_slow_tot out_slow_mc gc_total gc_ignored gc_goal_miss gc_dst_overflow in_hlist_search out_hlist_search\n'
        '00000010 00000000 00000005    00000000   00000001    00000000 00000000       00000002       00000000 00000020     00000001    00000000 00000000   00000000     0000000a        00000000        00000000\n'
    )
    rep_dst = mod.audit_conntrack(proc_sys_netfilter=str(netfilter_dir), proc_rt_cache=str(rt_f))
    assert rep_dst['summary']['status'] == 'CRITICAL'
    assert rep_dst['summary']['healthy'] is False
    assert rep_dst['summary']['rt_gc_dst_overflow'] == 10
"
echo "ok - mocked unit tests pass"

echo "All Pattern 207 tests passed successfully."
