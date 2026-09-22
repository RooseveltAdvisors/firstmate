#!/usr/bin/env bash
# tests/fm-jev-tso-guard.test.sh - Regression tests for Pattern 122 (TCP Segmentation Offload Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-tso-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-tso-guard.py"

echo "Running Pattern 122 regression tests..."

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
assert 'interfaces' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_limit_output_bytes' in s
assert 'default_qdisc' in s
assert 'active_interfaces' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and sysfs files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-tso-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    limit_file = d / 'tcp_limit_output_bytes'
    qdisc_file = d / 'default_qdisc'
    net_dir = d / 'net'
    net_dir.mkdir()

    (net_dir / 'eth0').mkdir()
    (net_dir / 'eth0' / 'operstate').write_text('up\n')

    limit_file.write_text('4194304\n')
    qdisc_file.write_text('fq_codel\n')

    # Case 1: Nominal
    res = mod.audit_tso(
        limit_file=str(limit_file),
        qdisc_file=str(qdisc_file),
        net_dir=str(net_dir),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_limit_output_bytes'] == 4194304
    assert res['summary']['default_qdisc'] == 'fq_codel'

    # Case 2: Low limit_output_bytes warning
    limit_file.write_text('65536\n')
    res2 = mod.audit_tso(
        limit_file=str(limit_file),
        qdisc_file=str(qdisc_file),
        net_dir=str(net_dir),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('tcp_limit_output_bytes is low' in iss for iss in res2['summary']['issues'])
"
echo "ok - mocked sysctl unit tests pass"

echo "All Pattern 122 tests passed successfully!"
