#!/usr/bin/env bash
# tests/fm-jev-sack-guard.test.sh - Regression tests for Pattern 210 (TCP SACK Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-sack-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-sack-guard.py"

echo "Running Pattern 210 regression tests..."

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
assert isinstance(s['tcp_sack_enabled'], bool)
assert isinstance(s['tcp_dsack_enabled'], bool)
assert isinstance(s['ofo_queued_packets'], int)
assert isinstance(s['ofo_dropped_packets'], int)
assert isinstance(s['sack_recoveries'], int)
assert isinstance(s['sack_failures'], int)
assert isinstance(s['issues'], list)
assert isinstance(s['recommendation'], str)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked procfs / sysfs files
python3 -c "
import sys, tempfile
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-sack-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    ipv4_dir = d / 'ipv4'
    ipv4_dir.mkdir()
    netstat_f = d / 'netstat'

    (ipv4_dir / 'tcp_sack').write_text('1\n')
    (ipv4_dir / 'tcp_dsack').write_text('1\n')
    (ipv4_dir / 'tcp_reordering').write_text('3\n')
    (ipv4_dir / 'tcp_recovery').write_text('1\n')

    # Mock clean netstat
    netstat_f.write_text(
        'TcpExt: SyncookiesSent SyncookiesRecv SyncookiesFailed TCPOFOQueue TCPOFODrop TCPOFOMerge TCPSackRecovery TCPSackFailures TCPSACKReorder TCPLostRetransmit TCPRetransFail\n'
        'TcpExt: 0 0 0 10000 1 500 5000 10 1000 5 1\n'
    )

    rep = mod.audit_sack_guard(proc_netstat=str(netstat_f), proc_sys_ipv4=str(ipv4_dir))
    s = rep['summary']
    assert s['status'] == 'HEALTHY'
    assert s['healthy'] is True
    assert s['tcp_sack_enabled'] is True
    assert s['ofo_queued_packets'] == 10000
    assert s['ofo_dropped_packets'] == 1
    assert s['sack_recoveries'] == 5000
    assert s['sack_failures'] == 10

    # Mock Critical condition: tcp_sack disabled
    (ipv4_dir / 'tcp_sack').write_text('0\n')
    rep_crit = mod.audit_sack_guard(proc_netstat=str(netstat_f), proc_sys_ipv4=str(ipv4_dir))
    assert rep_crit['summary']['status'] == 'CRITICAL'
    assert rep_crit['summary']['healthy'] is False
    assert any('tcp_sack is disabled' in iss for iss in rep_crit['summary']['issues'])

    # Mock Warning condition: high OFO drop ratio
    (ipv4_dir / 'tcp_sack').write_text('1\n')
    netstat_f.write_text(
        'TcpExt: SyncookiesSent SyncookiesRecv SyncookiesFailed TCPOFOQueue TCPOFODrop TCPOFOMerge TCPSackRecovery TCPSackFailures TCPSACKReorder TCPLostRetransmit TCPRetransFail\n'
        'TcpExt: 0 0 0 2000 200 500 5000 10 1000 5 1\n'
    )
    rep_warn = mod.audit_sack_guard(proc_netstat=str(netstat_f), proc_sys_ipv4=str(ipv4_dir))
    assert rep_warn['summary']['status'] == 'WARNING'
    assert rep_warn['summary']['healthy'] is False
    assert any('Out-Of-Order queue drop ratio' in iss for iss in rep_warn['summary']['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 210 tests passed successfully."
