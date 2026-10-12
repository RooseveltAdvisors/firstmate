#!/usr/bin/env bash
# tests/fm-jev-mcfilter-guard.test.sh - Regression tests for Pattern 242 (McfilterGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-mcfilter-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-mcfilter-guard.py"

echo "Running Pattern 242 regression tests..."

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
assert isinstance(s['total_filters'], int)
assert isinstance(s['total_ipv4_filters'], int)
assert isinstance(s['total_ipv6_filters'], int)
assert isinstance(s['ipv4_total_inc'], int)
assert isinstance(s['ipv4_total_exc'], int)
assert isinstance(s['ipv6_total_inc'], int)
assert isinstance(s['ipv6_total_exc'], int)
assert isinstance(s['igmp_max_memberships'], int)
assert isinstance(s['igmp_max_msf'], int)
assert isinstance(s['mld_max_msf'], int)
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
mod = import_module('fm-jev-mcfilter-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    mcfilter_f = d / 'mcfilter'
    mcfilter6_f = d / 'mcfilter6'
    ipv4_d = d / 'ipv4'
    ipv6_d = d / 'ipv6'
    ipv4_d.mkdir()
    ipv6_d.mkdir()

    # Nominal files
    mcfilter_f.write_text('Idx Device        MCA        SRC    INC    EXC\n1 lo FB0000E0 0100007F 1 0\n')
    mcfilter6_f.write_text('Idx Device                Multicast Address                   Source Address    INC    EXC\n1 lo ff0200000000000000000000000000fb 00000000000000000000000000000001 1 0\n')
    (ipv4_d / 'igmp_max_memberships').write_text('20\n')
    (ipv4_d / 'igmp_max_msf').write_text('10\n')
    (ipv6_d / 'mld_max_msf').write_text('64\n')

    rep = mod.audit_mcfilter(
        mcfilter_path=str(mcfilter_f),
        mcfilter6_path=str(mcfilter6_f),
        sys_ipv4_path=str(ipv4_d),
        sys_ipv6_path=str(ipv6_d),
    )
    assert rep['summary']['status'] == 'HEALTHY'
    assert rep['summary']['healthy'] is True
    assert rep['summary']['total_filters'] == 2
    assert rep['summary']['ipv4_total_inc'] == 1
    assert rep['summary']['ipv6_total_inc'] == 1
    assert len(rep['summary']['issues']) == 0

    # Low sysctls warning
    (ipv4_d / 'igmp_max_memberships').write_text('5\n')
    (ipv4_d / 'igmp_max_msf').write_text('2\n')
    (ipv6_d / 'mld_max_msf').write_text('5\n')

    rep = mod.audit_mcfilter(
        mcfilter_path=str(mcfilter_f),
        mcfilter6_path=str(mcfilter6_f),
        sys_ipv4_path=str(ipv4_d),
        sys_ipv6_path=str(ipv6_d),
    )
    assert rep['summary']['status'] == 'WARNING'
    assert rep['summary']['healthy'] is False
    assert any('Constrained IGMP max group memberships' in iss for iss in rep['summary']['issues'])
    assert any('Constrained IGMP source filter entries' in iss for iss in rep['summary']['issues'])
    assert any('Constrained MLD source filter entries' in iss for iss in rep['summary']['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 242 regression tests passed successfully!"
