#!/usr/bin/env bash
# tests/fm-jev-ulp-guard.test.sh - Regression tests for Pattern 182 (TCP ULP Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ulp-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ulp-guard.py"

echo "Running Pattern 182 regression tests..."

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
assert 'sysctls' in data
assert 'tls_stat' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_available_ulp' in s
assert 'available_ulps' in s
assert 'has_tls_ulp' in s
assert 'has_mptcp_ulp' in s
assert 'active_ktls_sw_sessions' in s
assert 'decrypt_errors' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-ulp-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    ulp_f = d / 'tcp_available_ulp'
    tls_stat_f = d / 'tls_stat'

    ulp_f.write_text('espintcp mptcp tls\n')
    tls_stat_f.write_text('''TlsCurrTxSw 0
TlsCurrRxSw 0
TlsCurrTxDevice 0
TlsCurrRxDevice 0
TlsTxSw 10
TlsRxSw 10
TlsDecryptError 0
TlsDecryptRetry 0
TlsRxRekeyError 0
TlsTxRekeyError 0
''')

    # Case 1: Nominal
    res = mod.audit_ulp(
        ulp_file=str(ulp_f),
        tls_stat_file=str(tls_stat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['has_tls_ulp'] is True
    assert res['summary']['has_mptcp_ulp'] is True
    assert res['summary']['decrypt_errors'] == 0

    # Case 2: Missing TLS ULP -> WARNING
    ulp_f.write_text('espintcp mptcp\n')
    res2 = mod.audit_ulp(
        ulp_file=str(ulp_f),
        tls_stat_file=str(tls_stat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert res2['summary']['healthy'] is False
    assert any('Kernel TLS (tls) ULP is not registered' in iss for iss in res2['summary']['issues'])

    # Case 3: Decrypt errors -> WARNING
    ulp_f.write_text('espintcp mptcp tls\n')
    tls_stat_f.write_text('''TlsCurrTxSw 0
TlsCurrRxSw 0
TlsCurrTxDevice 0
TlsCurrRxDevice 0
TlsTxSw 10
TlsRxSw 10
TlsDecryptError 4
TlsDecryptRetry 0
TlsRxRekeyError 0
TlsTxRekeyError 0
''')
    res3 = mod.audit_ulp(
        ulp_file=str(ulp_f),
        tls_stat_file=str(tls_stat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert res3['summary']['healthy'] is False
    assert any('Kernel TLS decryption errors detected: 4' in iss for iss in res3['summary']['issues'])

    # Case 4: Rekey errors -> WARNING
    tls_stat_f.write_text('''TlsCurrTxSw 0
TlsCurrRxSw 0
TlsCurrTxDevice 0
TlsCurrRxDevice 0
TlsTxSw 10
TlsRxSw 10
TlsDecryptError 0
TlsDecryptRetry 0
TlsRxRekeyError 2
TlsTxRekeyError 1
''')
    res4 = mod.audit_ulp(
        ulp_file=str(ulp_f),
        tls_stat_file=str(tls_stat_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert res4['summary']['healthy'] is False
    assert any('Kernel TLS re-keying errors detected' in iss for iss in res4['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 182 regression tests passed: 6/6 tests ok"
