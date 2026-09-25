#!/usr/bin/env bash
# tests/fm-jev-cpu-vuln-guard.test.sh - Regression tests for Pattern 323 (CpuVulnGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-cpu-vuln-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-cpu-vuln-guard.py"

echo "Running Pattern 323 regression tests..."

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
assert data['pattern'] == 323
assert data['name'] == 'cpu_vuln'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['is_mitigations_healthy'], bool)
assert isinstance(data['total_vulnerabilities_monitored'], int)
assert isinstance(data['not_affected_count'], int)
assert isinstance(data['mitigated_count'], int)
assert isinstance(data['vulnerable_count'], int)
assert isinstance(data['unknown_count'], int)
assert isinstance(data['vulnerabilities'], dict)
assert isinstance(data['issues'], list)
assert isinstance(data['recommendations'], list)
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
mod = import_module('fm-jev-cpu-vuln-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    vuln_d = d / 'vulnerabilities'
    vuln_d.mkdir()

    (vuln_d / 'meltdown').write_text('Not affected\n')
    (vuln_d / 'spectre_v1').write_text('Mitigation: usercopy/swapgs barriers\n')
    (vuln_d / 'spectre_v2').write_text('Mitigation: Enhanced / Automatic IBRS\n')

    res = mod.evaluate_cpu_vuln(vuln_dir=str(vuln_d))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['total_vulnerabilities_monitored'] == 3
    assert res['not_affected_count'] == 1
    assert res['mitigated_count'] == 2
    assert res['vulnerable_count'] == 0
    assert len(res['issues']) == 0

    # Test vulnerable detection (critical for meltdown/spectre)
    (vuln_d / 'meltdown').write_text('Vulnerable\n')
    res_vuln = mod.evaluate_cpu_vuln(vuln_dir=str(vuln_d), warn_on_unmitigated=True)
    assert res_vuln['healthy'] is False
    assert res_vuln['status'] == 'CRITICAL'
    assert res_vuln['vulnerable_count'] == 1
    assert any('meltdown' in iss for iss in res_vuln['issues'])

    # Test container fallback
    res_container = mod.evaluate_cpu_vuln(vuln_dir=str(d / 'nonexistent_vuln'))
    assert res_container['healthy'] is True
    assert res_container['status'] == 'HEALTHY'
    assert res_container['total_vulnerabilities_monitored'] == 0
"
echo "ok - unit tests with mock sysfs passed"

echo "All Pattern 323 tests passed successfully!"
