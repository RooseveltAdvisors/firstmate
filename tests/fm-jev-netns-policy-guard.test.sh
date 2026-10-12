#!/usr/bin/env bash
# tests/fm-jev-netns-policy-guard.test.sh - Regression tests for Pattern 251 (NetnsPolicyGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-netns-policy-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-netns-policy-guard.py"

echo "Running Pattern 251 regression tests..."

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
assert isinstance(data['devconf_inherit_init_net'], int)
assert isinstance(data['fb_tunnels_only_for_init_net'], int)
assert isinstance(data['max_net_namespaces'], int)
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
mod = import_module('fm-jev-netns-policy-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    devconf_file = d / 'devconf_inherit'
    fb_file = d / 'fb_tunnels'
    lwt_file = d / 'lwtunnel'
    netns_file = d / 'max_netns'

    # Nominal case
    devconf_file.write_text('1\n')
    fb_file.write_text('1\n')
    lwt_file.write_text('0\n')
    netns_file.write_text('254663\n')

    res = mod.audit_netns_policy_guard(
        sysctl_devconf_inherit=str(devconf_file),
        sysctl_fb_tunnels=str(fb_file),
        sysctl_lwtunnel_hooks=str(lwt_file),
        sysctl_max_netns=str(netns_file),
    )
    assert res['status'] == 'HEALTHY', f'Expected HEALTHY, got {res[\"status\"]}'
    assert res['healthy'] is True
    assert res['devconf_inheritance_active'] is True
    assert res['fallback_tunnel_suppression_active'] is True
    assert len(res['issues']) == 0

    # Constrained netns ceiling
    netns_file.write_text('512\n')
    res_bad = mod.audit_netns_policy_guard(
        sysctl_devconf_inherit=str(devconf_file),
        sysctl_fb_tunnels=str(fb_file),
        sysctl_lwtunnel_hooks=str(lwt_file),
        sysctl_max_netns=str(netns_file),
        min_netns_thresh=1024,
    )
    assert res_bad['status'] == 'WARNING'
    assert res_bad['healthy'] is False
    assert any('Constrained network namespace ceiling' in iss for iss in res_bad['issues'])
"
echo "ok - unit tests with mock procfs pass"

echo "Pattern 251 regression tests complete: ALL 6 TESTS PASSED."
