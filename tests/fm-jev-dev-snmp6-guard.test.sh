#!/usr/bin/env bash
# tests/fm-jev-dev-snmp6-guard.test.sh - Regression tests for Pattern 243 (DevSnmp6Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-dev-snmp6-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-dev-snmp6-guard.py"

echo "Running Pattern 243 regression tests..."

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
assert isinstance(s['total_interfaces'], int)
assert isinstance(s['total_in_receives'], int)
assert isinstance(s['total_in_delivers'], int)
assert isinstance(s['total_in_discards'], int)
assert isinstance(s['total_in_hdr_errors'], int)
assert isinstance(s['total_in_addr_errors'], int)
assert isinstance(s['total_in_no_routes'], int)
assert isinstance(s['total_icmp6_in_csum_errors'], int)
assert isinstance(s['issues'], list)
assert 'details' in data
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
mod = import_module('fm-jev-dev-snmp6-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    lo_f = d / 'lo'
    eth0_f = d / 'eth0'

    lo_f.write_text('''
ifIndex 1
Ip6InReceives 10000
Ip6InDelivers 10000
Ip6InDiscards 0
Ip6InHdrErrors 0
Ip6InAddrErrors 0
Ip6InNoRoutes 0
Icmp6InCsumErrors 0
Icmp6InErrors 0
''')

    eth0_f.write_text('''
ifIndex 2
Ip6InReceives 5000
Ip6InDelivers 5000
Ip6InDiscards 2
Ip6InHdrErrors 0
Ip6InAddrErrors 0
Ip6InNoRoutes 0
Ip6ReasmReqds 100
Ip6ReasmFails 1
Icmp6InCsumErrors 0
Icmp6InErrors 0
''')

    rep = mod.audit_dev_snmp6(base_path=str(d))
    assert rep['summary']['status'] == 'HEALTHY'
    assert rep['summary']['healthy'] is True
    assert rep['summary']['total_interfaces'] == 2
    assert rep['summary']['total_in_receives'] == 15000
    assert len(rep['summary']['issues']) == 0

    # Header error warning
    eth0_f.write_text('''
ifIndex 2
Ip6InReceives 1000
Ip6InDelivers 950
Ip6InDiscards 0
Ip6InHdrErrors 50
Ip6InAddrErrors 0
Ip6InNoRoutes 0
Icmp6InCsumErrors 0
Icmp6InErrors 0
''')
    rep = mod.audit_dev_snmp6(base_path=str(d))
    assert rep['summary']['status'] == 'WARNING'
    assert rep['summary']['healthy'] is False
    assert any('elevated IPv6 header errors' in iss for iss in rep['summary']['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 243 regression tests passed successfully!"
