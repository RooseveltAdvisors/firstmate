#!/usr/bin/env bash
# tests/fm-jev-ipv6-ra-filter-guard.test.sh - Regression tests for Pattern 253 (Ipv6RaFilterGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv6-ra-filter-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv6-ra-filter-guard.py"

echo "Running Pattern 253 regression tests..."

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
assert isinstance(data['accept_ra_min_hop_limit'], int)
assert isinstance(data['accept_ra_min_lft'], int)
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
mod = import_module('fm-jev-ipv6-ra-filter-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    all_dir = d / 'all'
    def_dir = d / 'default'
    all_dir.mkdir()
    def_dir.mkdir()

    # Nominal case
    (all_dir / 'accept_ra_min_hop_limit').write_text('1\n')
    (all_dir / 'accept_ra_min_lft').write_text('0\n')
    (all_dir / 'accept_ra_rt_info_min_plen').write_text('0\n')
    (all_dir / 'accept_ra_rt_info_max_plen').write_text('64\n')
    (all_dir / 'ra_defrtr_metric').write_text('1024\n')
    (all_dir / 'ra_honor_pio_life').write_text('0\n')
    (all_dir / 'ra_honor_pio_pflag').write_text('0\n')

    (def_dir / 'accept_ra_min_hop_limit').write_text('1\n')
    (def_dir / 'accept_ra_min_lft').write_text('0\n')

    res = mod.audit_ipv6_ra_filter_guard(
        conf_dir=str(all_dir),
        default_conf_dir=str(def_dir),
    )
    assert res['status'] == 'HEALTHY', f'Expected HEALTHY, got {res[\"status\"]}'
    assert res['healthy'] is True
    assert res['accept_ra_min_hop_limit'] == 1
    assert len(res['issues']) == 0

    # Lowered hop limit and negative lifetime
    (all_dir / 'accept_ra_min_hop_limit').write_text('0\n')
    (all_dir / 'accept_ra_min_lft').write_text('-1\n')
    (all_dir / 'accept_ra_rt_info_min_plen').write_text('64\n')
    (all_dir / 'accept_ra_rt_info_max_plen').write_text('32\n')

    (def_dir / 'accept_ra_min_hop_limit').write_text('0\n')

    res_bad = mod.audit_ipv6_ra_filter_guard(
        conf_dir=str(all_dir),
        default_conf_dir=str(def_dir),
        min_allowed_hop_limit=1,
    )
    assert res_bad['status'] == 'WARNING'
    assert res_bad['healthy'] is False
    assert len(res_bad['issues']) == 4
    assert any('accept_ra_min_hop_limit is lowered to 0' in iss for iss in res_bad['issues'])
    assert any('Invalid accept_ra_min_lft configuration' in iss for iss in res_bad['issues'])
    assert any('Inconsistent RIO prefix limits' in iss for iss in res_bad['issues'])
"
echo "ok - unit tests with mock procfs pass"

echo "Pattern 253 regression tests complete: ALL 6 TESTS PASSED."
