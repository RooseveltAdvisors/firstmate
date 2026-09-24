#!/usr/bin/env bash
# tests/fm-jev-ipv6-ext-hdr-guard.test.sh - Regression tests for Pattern 252 (Ipv6ExtHdrGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv6-ext-hdr-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv6-ext-hdr-guard.py"

echo "Running Pattern 252 regression tests..."

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
assert isinstance(data['max_hbh_opts_number'], int)
assert isinstance(data['max_dst_opts_number'], int)
assert isinstance(data['in_hdr_errors'], int)
assert isinstance(data['in_truncated_pkts'], int)
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
mod = import_module('fm-jev-ipv6-ext-hdr-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    hbh_opts_file = d / 'max_hbh_opts_number'
    hbh_len_file = d / 'max_hbh_length'
    dst_opts_file = d / 'max_dst_opts_number'
    dst_len_file = d / 'max_dst_opts_length'
    snmp6_file = d / 'snmp6'

    # Nominal case
    hbh_opts_file.write_text('8\n')
    hbh_len_file.write_text('2147483647\n')
    dst_opts_file.write_text('8\n')
    dst_len_file.write_text('2147483647\n')
    snmp6_file.write_text('Ip6InReceives 1000\nIp6InHdrErrors 0\nIp6InUnknownProtos 0\nIp6InTruncatedPkts 0\nIp6InDiscards 0\nIp6InDelivers 1000\n')

    res = mod.audit_ipv6_ext_hdr_guard(
        max_hbh_opts_path=str(hbh_opts_file),
        max_hbh_length_path=str(hbh_len_file),
        max_dst_opts_path=str(dst_opts_file),
        max_dst_opts_length_path=str(dst_len_file),
        snmp6_path=str(snmp6_file),
    )
    assert res['status'] == 'HEALTHY', f'Expected HEALTHY, got {res[\"status\"]}'
    assert res['healthy'] is True
    assert res['max_hbh_opts_number'] == 8
    assert res['max_dst_opts_number'] == 8
    assert len(res['issues']) == 0

    # Overly permissive limits and elevated errors
    hbh_opts_file.write_text('32\n')
    dst_opts_file.write_text('64\n')
    snmp6_file.write_text('Ip6InReceives 5000\nIp6InHdrErrors 120\nIp6InUnknownProtos 5\nIp6InTruncatedPkts 35\nIp6InDiscards 155\nIp6InDelivers 4845\n')

    res_bad = mod.audit_ipv6_ext_hdr_guard(
        max_hbh_opts_path=str(hbh_opts_file),
        max_hbh_length_path=str(hbh_len_file),
        max_dst_opts_path=str(dst_opts_file),
        max_dst_opts_length_path=str(dst_len_file),
        snmp6_path=str(snmp6_file),
        warn_max_hbh_opts=16,
        warn_max_dst_opts=16,
        warn_hdr_errors=50,
        warn_truncated_pkts=10,
    )
    assert res_bad['status'] == 'WARNING'
    assert res_bad['healthy'] is False
    assert len(res_bad['issues']) == 4
    assert any('max_hbh_opts_number is overly permissive' in iss for iss in res_bad['issues'])
    assert any('max_dst_opts_number is overly permissive' in iss for iss in res_bad['issues'])
    assert any('Elevated IPv6 inbound header errors' in iss for iss in res_bad['issues'])
    assert any('Elevated IPv6 truncated packets' in iss for iss in res_bad['issues'])
"
echo "ok - unit tests with mock procfs pass"

echo "Pattern 252 regression tests complete: ALL 6 TESTS PASSED."
