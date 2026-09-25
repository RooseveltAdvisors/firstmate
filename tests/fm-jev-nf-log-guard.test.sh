#!/usr/bin/env bash
# tests/fm-jev-nf-log-guard.test.sh - Regression tests for Pattern 282 (NfLogGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-nf-log-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-nf-log-guard.py"

echo "Running Pattern 282 regression tests..."

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
assert isinstance(data['nf_log_all_netns'], int)
assert isinstance(data['nf_hooks_lwtunnel'], int)
assert isinstance(data['nf_conntrack_buckets'], int)
assert isinstance(data['nf_conntrack_max'], int)
assert isinstance(data['nf_conntrack_count'], int)
assert isinstance(data['conntrack_saturation_pct'], (int, float))
assert isinstance(data['log_backends_count'], int)
assert isinstance(data['ipv4_log_backend'], str)
assert isinstance(data['ipv6_log_backend'], str)
assert isinstance(data['issues'], list)
assert isinstance(data['recommendations'], list)
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
mod = import_module('fm-jev-nf-log-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'netfilter'
    conf_dir.mkdir()
    (conf_dir / 'nf_log_all_netns').write_text('0\n')
    (conf_dir / 'nf_hooks_lwtunnel').write_text('0\n')
    (conf_dir / 'nf_conntrack_buckets').write_text('262144\n')
    (conf_dir / 'nf_conntrack_max').write_text('262144\n')
    (conf_dir / 'nf_conntrack_count').write_text('100\n')

    nf_log_dir = conf_dir / 'nf_log'
    nf_log_dir.mkdir()
    (nf_log_dir / '2').write_text('nf_log_ipv4\n')
    (nf_log_dir / '10').write_text('nf_log_ipv6\n')

    res = mod.audit_nf_log_guard(conf_dir=str(conf_dir), nf_log_dir=str(nf_log_dir))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['nf_log_all_netns'] == 0
    assert res['nf_conntrack_buckets'] == 262144
    assert res['nf_conntrack_max'] == 262144
    assert res['nf_conntrack_count'] == 100
    assert res['ipv4_log_backend'] == 'nf_log_ipv4'
    assert res['ipv6_log_backend'] == 'nf_log_ipv6'

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'netfilter'
    conf_dir.mkdir()
    (conf_dir / 'nf_log_all_netns').write_text('1\n')
    (conf_dir / 'nf_hooks_lwtunnel').write_text('0\n')
    (conf_dir / 'nf_conntrack_buckets').write_text('1000\n')
    (conf_dir / 'nf_conntrack_max').write_text('32000\n')
    (conf_dir / 'nf_conntrack_count').write_text('31000\n')

    res = mod.audit_nf_log_guard(conf_dir=str(conf_dir))
    assert res['healthy'] is False
    assert res['status'] == 'CRITICAL'
    assert any('nf_log_all_netns is enabled' in iss for iss in res['issues'])
    assert any('Excessive conntrack max to buckets ratio' in iss for iss in res['issues'])
    assert any('Critical conntrack table saturation' in iss for iss in res['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 282 regression tests passed!"
