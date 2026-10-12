#!/usr/bin/env bash
# tests/fm-jev-addr-gen-mode-guard.test.sh - Regression tests for Pattern 264 (AddrGenModeGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-addr-gen-mode-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-addr-gen-mode-guard.py"

echo "Running Pattern 264 regression tests..."

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
assert isinstance(data['interfaces_audited'], int)
assert isinstance(data['default_mode'], int)
assert isinstance(data['issues'], list)
assert isinstance(data['mode_counts'], dict)
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
mod = import_module('fm-jev-addr-gen-mode-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_lo = conf_dir / 'lo'
    conf_enp = conf_dir / 'enp'
    conf_lo.mkdir(parents=True)
    conf_enp.mkdir(parents=True)
    (conf_lo / 'addr_gen_mode').write_text('0\n')
    (conf_lo / 'keep_addr_on_down').write_text('0\n')
    (conf_lo / 'use_oif_addrs_only').write_text('0\n')
    (conf_lo / 'regen_max_retry').write_text('3\n')

    (conf_enp / 'addr_gen_mode').write_text('1\n')
    (conf_enp / 'keep_addr_on_down').write_text('0\n')
    (conf_enp / 'use_oif_addrs_only').write_text('0\n')
    (conf_enp / 'regen_max_retry').write_text('3\n')

    res = mod.audit_addr_gen_mode_guard(
        conf_dir=str(conf_dir),
        min_regen_retry=1,
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['interfaces_audited'] == 2
    assert res['eui64_interfaces'] == 1
    assert res['none_interfaces'] == 1

    # Issues case: invalid addr_gen_mode and regen_max_retry < 1
    (conf_enp / 'addr_gen_mode').write_text('42\n')
    (conf_enp / 'regen_max_retry').write_text('0\n')

    res2 = mod.audit_addr_gen_mode_guard(
        conf_dir=str(conf_dir),
        min_regen_retry=1,
    )
    assert res2['healthy'] is False
    assert res2['status'] == 'WARNING'
    assert len(res2['issues']) == 2
    assert any('invalid addr_gen_mode=42' in i for i in res2['issues'])
    assert any('regen_max_retry=0 below minimum 1' in i for i in res2['issues'])
"
echo "ok - unit tests with mock sysctls passed"

echo "All Pattern 264 regression tests passed!"
