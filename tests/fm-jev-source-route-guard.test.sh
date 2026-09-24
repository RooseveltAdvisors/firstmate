#!/usr/bin/env bash
# tests/fm-jev-source-route-guard.test.sh - Regression tests for Pattern 248 (SourceRouteGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-source-route-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-source-route-guard.py"

echo "Running Pattern 248 regression tests..."

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
assert isinstance(data['ipv4_all'], int)
assert isinstance(data['ipv6_all'], int)
assert isinstance(data['rfc5095_compliant'], bool)
assert isinstance(data['source_route_prohibited'], bool)
assert isinstance(data['ipv4_interfaces'], dict)
assert isinstance(data['ipv6_interfaces'], dict)
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
mod = import_module('fm-jev-source-route-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    v4_dir = d / 'ipv4'
    v6_dir = d / 'ipv6'
    (v4_dir / 'all').mkdir(parents=True)
    (v4_dir / 'default').mkdir(parents=True)
    (v6_dir / 'all').mkdir(parents=True)
    (v6_dir / 'default').mkdir(parents=True)

    # Nominal case
    (v4_dir / 'all' / 'accept_source_route').write_text('0\n')
    (v4_dir / 'default' / 'accept_source_route').write_text('0\n')
    (v6_dir / 'all' / 'accept_source_route').write_text('0\n')
    (v6_dir / 'default' / 'accept_source_route').write_text('0\n')

    res = mod.audit_source_route_guard(ipv4_conf_dir=str(v4_dir), ipv6_conf_dir=str(v6_dir))
    assert res['status'] == 'HEALTHY', f'Expected HEALTHY, got {res[\"status\"]}'
    assert res['healthy'] is True
    assert res['rfc5095_compliant'] is True
    assert res['source_route_prohibited'] is True
    assert len(res['issues']) == 0

    # Misconfigured IPv6 RH0 enabled
    (v6_dir / 'all' / 'accept_source_route').write_text('1\n')
    res_v6 = mod.audit_source_route_guard(ipv4_conf_dir=str(v4_dir), ipv6_conf_dir=str(v6_dir))
    assert res_v6['status'] == 'CRITICAL'
    assert res_v6['healthy'] is False
    assert res_v6['rfc5095_compliant'] is False
    assert any('Type 0 Routing Header' in iss for iss in res_v6['issues'])
"
echo "ok - unit tests with mock procfs pass"

echo "Pattern 248 regression tests complete: ALL 6 TESTS PASSED."
