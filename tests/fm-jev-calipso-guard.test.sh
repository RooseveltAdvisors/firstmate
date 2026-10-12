#!/usr/bin/env bash
# tests/fm-jev-calipso-guard.test.sh - Regression tests for Pattern 254 (CalipsoGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-calipso-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-calipso-guard.py"

echo "Running Pattern 254 regression tests..."

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
assert isinstance(data['calipso_cache_enable'], int)
assert isinstance(data['calipso_cache_bucket_size'], int)
assert isinstance(data['in_receives'], int)
assert isinstance(data['in_hdr_errors'], int)
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
mod = import_module('fm-jev-calipso-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    cache_file = d / 'calipso_cache_enable'
    bucket_file = d / 'calipso_cache_bucket_size'
    snmp6_file = d / 'snmp6'

    # Nominal case
    cache_file.write_text('1\n')
    bucket_file.write_text('10\n')
    snmp6_file.write_text('Ip6InReceives 10000\nIp6InHdrErrors 0\nIp6InTruncatedPkts 0\nIp6InDiscards 0\n')

    res = mod.audit_calipso_guard(
        cache_enable_path=str(cache_file),
        bucket_size_path=str(bucket_file),
        snmp6_path=str(snmp6_file),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['calipso_cache_enable'] == 1
    assert res['calipso_cache_bucket_size'] == 10

    # Warning / Critical case: disabled cache, large bucket, high errors
    cache_file.write_text('0\n')
    bucket_file.write_text('120\n')
    snmp6_file.write_text('Ip6InReceives 10000\nIp6InHdrErrors 100\nIp6InTruncatedPkts 100\nIp6InDiscards 50\n')

    res2 = mod.audit_calipso_guard(
        cache_enable_path=str(cache_file),
        bucket_size_path=str(bucket_file),
        snmp6_path=str(snmp6_file),
    )
    assert res2['healthy'] is False
    assert res2['status'] == 'CRITICAL'
    assert len(res2['issues']) == 4
    assert any('CALIPSO attribute caching disabled' in i for i in res2['issues'])
    assert any('Elevated net.ipv6.calipso_cache_bucket_size' in i for i in res2['issues'])
    assert any('Critical IPv6 header error rate' in i for i in res2['issues'])
    assert any('Critical IPv6 truncated packet rate' in i for i in res2['issues'])
"
echo "ok - unit tests with mock sysctls passed"

echo "All Pattern 254 regression tests passed!"
