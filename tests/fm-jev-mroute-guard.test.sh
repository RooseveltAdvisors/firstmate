#!/usr/bin/env bash
# tests/fm-jev-mroute-guard.test.sh - Regression tests for Pattern 249 (MrouteGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-mroute-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-mroute-guard.py"

echo "Running Pattern 249 regression tests..."

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
assert isinstance(data['ipv4_mc_forwarding_all'], int)
assert isinstance(data['ipv6_mc_forwarding_all'], int)
assert isinstance(data['total_vifs'], int)
assert isinstance(data['total_routes'], int)
assert isinstance(data['total_rpf_failures'], int)
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
mod = import_module('fm-jev-mroute-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    v4_vif = d / 'ip_mr_vif'
    v4_cache = d / 'ip_mr_cache'
    v6_vif = d / 'ip6_mr_vif'
    v6_cache = d / 'ip6_mr_cache'

    # Nominal empty case
    v4_vif.write_text('Interface      BytesIn  PktsIn  BytesOut PktsOut Flags Local    Remote\n')
    v4_cache.write_text('Group    Origin   Iif     Pkts    Bytes    Wrong Oifs\n')
    v6_vif.write_text('Interface      BytesIn  PktsIn  BytesOut PktsOut Flags\n')
    v6_cache.write_text('Group                            Origin                           Iif      Pkts  Bytes     Wrong  Oifs\n')

    res = mod.audit_mroute_guard(
        vif_ipv4_path=str(v4_vif),
        cache_ipv4_path=str(v4_cache),
        vif_ipv6_path=str(v6_vif),
        cache_ipv6_path=str(v6_cache),
    )
    assert res['status'] == 'HEALTHY', f'Expected HEALTHY, got {res[\"status\"]}'
    assert res['healthy'] is True
    assert res['total_vifs'] == 0
    assert res['total_routes'] == 0
    assert res['total_rpf_failures'] == 0
    assert len(res['issues']) == 0

    # Populated table with high RPF drops
    v4_cache.write_text('Group    Origin   Iif     Pkts    Bytes    Wrong Oifs\nE8000101 0100007F 0 100 12000 150 1:1\n')
    res_bad = mod.audit_mroute_guard(
        vif_ipv4_path=str(v4_vif),
        cache_ipv4_path=str(v4_cache),
        vif_ipv6_path=str(v6_vif),
        cache_ipv6_path=str(v6_cache),
        warn_rpf_drops=100,
    )
    assert res_bad['status'] == 'WARNING'
    assert res_bad['healthy'] is False
    assert res_bad['total_rpf_failures'] == 150
    assert any('Reverse Path Forwarding' in iss for iss in res_bad['issues'])
"
echo "ok - unit tests with mock procfs pass"

echo "Pattern 249 regression tests complete: ALL 6 TESTS PASSED."
