#!/usr/bin/env bash
# tests/fm-jev-nf-flowtable-guard.test.sh - Regression tests for Pattern 277 (NfFlowtableGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-nf-flowtable-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-nf-flowtable-guard.py"

echo "Running Pattern 277 regression tests..."

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
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['flowtable_tcp_timeout_sec'], int)
assert isinstance(data['flowtable_udp_timeout_sec'], int)
assert isinstance(data['generic_timeout_sec'], int)
assert isinstance(data['gre_timeout_sec'], int)
assert isinstance(data['gre_timeout_stream_sec'], int)
assert isinstance(data['conntrack_count'], int)
assert isinstance(data['conntrack_max'], int)
assert isinstance(data['table_saturation_pct'], float)
assert isinstance(data['gre_stream_hierarchy_ok'], bool)
assert isinstance(data['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked files
python3 -c "
import sys, tempfile
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-nf-flowtable-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    (d / 'nf_flowtable_tcp_timeout').write_text('30\n')
    (d / 'nf_flowtable_udp_timeout').write_text('30\n')
    (d / 'nf_conntrack_generic_timeout').write_text('600\n')
    (d / 'nf_conntrack_gre_timeout').write_text('30\n')
    (d / 'nf_conntrack_gre_timeout_stream').write_text('180\n')
    (d / 'nf_conntrack_count').write_text('1000\n')
    (d / 'nf_conntrack_max').write_text('262144\n')

    res = mod.audit_nf_flowtable_guard(conf_dir=str(d))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['flowtable_tcp_timeout_sec'] == 30
    assert res['generic_timeout_sec'] == 600
    assert res['gre_stream_hierarchy_ok'] is True

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    (d / 'nf_flowtable_tcp_timeout').write_text('500\n')
    (d / 'nf_flowtable_udp_timeout').write_text('500\n')
    (d / 'nf_conntrack_generic_timeout').write_text('5000\n')
    (d / 'nf_conntrack_gre_timeout').write_text('200\n')
    (d / 'nf_conntrack_gre_timeout_stream').write_text('50\n')
    (d / 'nf_conntrack_count').write_text('250000\n')
    (d / 'nf_conntrack_max').write_text('262144\n')

    res = mod.audit_nf_flowtable_guard(conf_dir=str(d))
    assert res['healthy'] is False
    assert res['status'] == 'CRITICAL'
    assert any('Excessive flowtable TCP timeout' in iss for iss in res['issues'])
    assert any('Excessive generic protocol conntrack timeout' in iss for iss in res['issues'])
    assert any('Inverted GRE timeout hierarchy' in iss for iss in res['issues'])
    assert any('Critical conntrack table saturation' in iss for iss in res['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 277 regression tests passed!"
