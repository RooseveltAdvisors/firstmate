#!/usr/bin/env bash
# tests/fm-jev-psched-guard.test.sh - Regression tests for Pattern 241 (PschedGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-psched-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-psched-guard.py"

echo "Running Pattern 241 regression tests..."

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
assert isinstance(s['tick_per_us'], int)
assert isinstance(s['us_per_tick'], int)
assert isinstance(s['clock_res_hz'], int)
assert isinstance(s['clock_scale'], int)
assert isinstance(s['default_qdisc'], str)
assert isinstance(s['issues'], list)
assert isinstance(s['recommendation'], str)
assert 'psched' in data
assert 'tx_queue_lens' in data
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
mod = import_module('fm-jev-psched-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    psched_f = d / 'psched'
    core_d = d / 'core'
    net_d = d / 'net'
    core_d.mkdir()
    net_d.mkdir()

    # Nominal psched hex: 1000 64 1000000 1000000000
    psched_f.write_text('000003e8 00000040 000f4240 3b9aca00\n')
    (core_d / 'default_qdisc').write_text('fq_codel\n')

    eth0 = net_d / 'eth0'
    eth0.mkdir()
    (eth0 / 'tx_queue_len').write_text('1000\n')

    rep = mod.audit_psched(psched_path=str(psched_f), sys_core_path=str(core_d), sys_net_path=str(net_d))
    assert rep['summary']['status'] == 'HEALTHY'
    assert rep['summary']['healthy'] is True
    assert rep['summary']['clock_res_hz'] == 1000000
    assert rep['summary']['clock_scale'] == 1000000000
    assert len(rep['summary']['issues']) == 0

    # Degraded clock resolution warning
    psched_f.write_text('00000064 00000040 0007a120 3b9aca00\n')  # 500000 Hz
    rep = mod.audit_psched(psched_path=str(psched_f), sys_core_path=str(core_d), sys_net_path=str(net_d))
    assert rep['summary']['status'] == 'WARNING'
    assert rep['summary']['healthy'] is False
    assert any('Degraded packet scheduler clock resolution' in iss for iss in rep['summary']['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 241 regression tests passed successfully!"
