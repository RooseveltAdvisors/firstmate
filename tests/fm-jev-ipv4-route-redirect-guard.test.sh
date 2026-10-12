#!/usr/bin/env bash
# tests/fm-jev-ipv4-route-redirect-guard.test.sh - Regression tests for Pattern 279 (Ipv4RouteRedirectGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv4-route-redirect-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv4-route-redirect-guard.py"

echo "Running Pattern 279 regression tests..."

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
assert isinstance(data['redirect_load'], int)
assert isinstance(data['redirect_number'], int)
assert isinstance(data['redirect_silence_ms'], int)
assert isinstance(data['error_cost_ms'], int)
assert isinstance(data['error_burst_ms'], int)
assert isinstance(data['gc_timeout_sec'], int)
assert isinstance(data['gc_interval_sec'], int)
assert isinstance(data['gc_min_interval_ms'], int)
assert isinstance(data['in_redirects'], int)
assert isinstance(data['out_redirects'], int)
assert isinstance(data['out_ratelimit_global'], int)
assert isinstance(data['out_ratelimit_host'], int)
assert isinstance(data['in_errors'], int)
assert isinstance(data['out_errors'], int)
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
mod = import_module('fm-jev-ipv4-route-redirect-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    route_dir = d / 'route'
    route_dir.mkdir()
    (route_dir / 'redirect_load').write_text('20\n')
    (route_dir / 'redirect_number').write_text('9\n')
    (route_dir / 'redirect_silence').write_text('20480\n')
    (route_dir / 'error_cost').write_text('1000\n')
    (route_dir / 'error_burst').write_text('5000\n')
    (route_dir / 'gc_timeout').write_text('300\n')
    (route_dir / 'gc_interval').write_text('60\n')
    (route_dir / 'gc_min_interval_ms').write_text('500\n')

    snmp_file = d / 'snmp'
    snmp_file.write_text(
        'Icmp: InMsgs InErrors InCsumErrors InDestUnreachs InTimeExcds InParmProbs InSrcQuenchs InRedirects InEchos InEchoReps InTimestamps InTimestampReps InAddrMasks InAddrMaskReps OutMsgs OutErrors OutRateLimitGlobal OutRateLimitHost OutDestUnreachs OutTimeExcds OutParmProbs OutSrcQuenchs OutRedirects OutEchos OutEchoReps OutTimestamps OutTimestampReps OutAddrMasks OutAddrMaskReps\n'
        'Icmp: 100 0 0 10 0 0 0 0 50 40 0 0 0 0 100 0 0 0 10 0 0 0 0 50 40 0 0 0 0\n'
    )

    res = mod.audit_ipv4_route_redirect_guard(route_dir=str(route_dir), snmp_file=str(snmp_file))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['redirect_load'] == 20
    assert res['redirect_number'] == 9

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    route_dir = d / 'route'
    route_dir.mkdir()
    (route_dir / 'redirect_load').write_text('20\n')
    (route_dir / 'redirect_number').write_text('0\n')
    (route_dir / 'redirect_silence').write_text('500\n')
    (route_dir / 'error_cost').write_text('0\n')
    (route_dir / 'error_burst').write_text('50\n')
    (route_dir / 'gc_timeout').write_text('5\n')
    (route_dir / 'gc_interval').write_text('2\n')
    (route_dir / 'gc_min_interval_ms').write_text('500\n')

    res = mod.audit_ipv4_route_redirect_guard(route_dir=str(route_dir), snmp_file=str(d / 'nonexistent'))
    assert res['healthy'] is False
    assert res['status'] == 'CRITICAL'
    assert any('Abnormally low redirect_number' in iss for iss in res['issues'])
    assert any('Dangerous redirect_silence' in iss for iss in res['issues'])
    assert any('Invalid error_cost' in iss for iss in res['issues'])
    assert any('Abnormally short route gc_timeout' in iss for iss in res['issues'])
    assert any('Excessively aggressive route gc_interval' in iss for iss in res['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 279 regression tests passed!"
