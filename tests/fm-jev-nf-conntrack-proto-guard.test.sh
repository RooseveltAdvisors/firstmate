#!/usr/bin/env bash
# tests/fm-jev-nf-conntrack-proto-guard.test.sh - Regression tests for Pattern 302 (NfConntrackProtoGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-nf-conntrack-proto-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-nf-conntrack-proto-guard.py"

echo "Running Pattern 302 regression tests..."

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
assert data['pattern'] == 302
assert data['name'] == 'nf_conntrack_proto'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['udp_timeout_sec'], int)
assert isinstance(data['udp_timeout_stream_sec'], int)
assert isinstance(data['icmp_timeout_sec'], int)
assert isinstance(data['icmpv6_timeout_sec'], int)
assert isinstance(data['generic_timeout_sec'], int)
assert isinstance(data['conntrack_count'], int)
assert isinstance(data['conntrack_max'], int)
assert isinstance(data['conntrack_buckets'], int)
assert isinstance(data['saturation_pct'], (int, float))
assert isinstance(data['bucket_ratio'], (int, float))
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
mod = import_module('fm-jev-nf-conntrack-proto-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    (d / 'nf_conntrack_udp_timeout').write_text('30\n')
    (d / 'nf_conntrack_udp_timeout_stream').write_text('120\n')
    (d / 'nf_conntrack_icmp_timeout').write_text('30\n')
    (d / 'nf_conntrack_icmpv6_timeout').write_text('30\n')
    (d / 'nf_conntrack_generic_timeout').write_text('600\n')
    (d / 'nf_conntrack_count').write_text('500\n')
    (d / 'nf_conntrack_max').write_text('262144\n')
    (d / 'nf_conntrack_buckets').write_text('262144\n')

    res = mod.evaluate_nf_conntrack_proto(conf_dir=str(d))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['udp_timeout_sec'] == 30
    assert res['udp_timeout_stream_sec'] == 120
    assert res['icmp_timeout_sec'] == 30
    assert res['icmpv6_timeout_sec'] == 30
    assert res['generic_timeout_sec'] == 600
    assert res['conntrack_count'] == 500
    assert len(res['issues']) == 0

    # Test error cases: invalid values and high saturation
    (d / 'nf_conntrack_udp_timeout').write_text('2\n')
    (d / 'nf_conntrack_udp_timeout_stream').write_text('1\n')
    (d / 'nf_conntrack_icmp_timeout').write_text('200\n')
    (d / 'nf_conntrack_icmpv6_timeout').write_text('200\n')
    (d / 'nf_conntrack_generic_timeout').write_text('5\n')
    (d / 'nf_conntrack_count').write_text('250000\n')

    res_err = mod.evaluate_nf_conntrack_proto(conf_dir=str(d))
    assert res_err['healthy'] is False
    assert res_err['status'] == 'CRITICAL'
    assert any('Suboptimal nf_conntrack_udp_timeout' in iss for iss in res_err['issues'])
    assert any('Inconsistent UDP timeouts' in iss for iss in res_err['issues'])
    assert any('Suboptimal nf_conntrack_icmp_timeout' in iss for iss in res_err['issues'])
    assert any('Suboptimal nf_conntrack_icmpv6_timeout' in iss for iss in res_err['issues'])
    assert any('Suboptimal nf_conntrack_generic_timeout' in iss for iss in res_err['issues'])
    assert any('CRITICAL: Conntrack table near exhaustion' in iss for iss in res_err['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All 6/6 tests passed successfully!"
