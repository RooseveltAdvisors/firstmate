#!/usr/bin/env bash
# tests/fm-jev-gate-resolver.test.sh - Verification suite for Pattern 227
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER_SH="${SCRIPT_DIR}/../bin/fm-jev-gate-resolver.sh"
RESOLVER_PY="${SCRIPT_DIR}/../bin/fm-jev-gate-resolver.py"

echo "=== Running fm-jev-gate-resolver test suite ==="

# 1. Executable check
test -x "${RESOLVER_SH}" || { echo "FAIL: ${RESOLVER_SH} not executable"; exit 1; }
test -x "${RESOLVER_PY}" || { echo "FAIL: ${RESOLVER_PY} not executable"; exit 1; }
echo "PASS: Executable bits verified"

# 2. Help flag verification
"${RESOLVER_SH}" --help > /dev/null
echo "PASS: Help flag returns 0"

# 3. Live audit run
LIVE_JSON="$("${RESOLVER_SH}" --json 2>&1 || true)"
echo "${LIVE_JSON}" | grep -q '"status":' || { echo "FAIL: JSON output missing status"; exit 1; }
echo "${LIVE_JSON}" | grep -q '"findings":' || { echo "FAIL: JSON output missing findings"; exit 1; }
echo "PASS: Live audit returns valid schema"

# Temporary directory setup for synthetic tests
TMP_DIR="$(mktemp -d /tmp/fm-jev-resolver-test.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# 4. Synthetic mechanical auto-fix finding
cat << 'EOF' > "${TMP_DIR}/nm-01MTEST001-findings.txt"
id: F1
severity: warning
file: src/cli/options.py
line: 42
description: Unused import typing.Optional can be removed via mechanical edit.
authority: auto-fix
EOF

AUTO_OUT="$("${RESOLVER_SH}" "${TMP_DIR}/nm-01MTEST001-findings.txt" --json)"
echo "${AUTO_OUT}" | grep -q '"status": "HEALTHY"' || { echo "FAIL: Expected HEALTHY for auto-fixable finding"; exit 1; }
echo "${AUTO_OUT}" | grep -q '"auto_fixable": 1' || { echo "FAIL: Expected auto_fixable count 1"; exit 1; }
echo "${AUTO_OUT}" | grep -q 'authorize_mechanical_fix' || { echo "FAIL: Expected authorize_mechanical_fix action"; exit 1; }
echo "PASS: Mechanical auto-fix finding classified accurately"

# 5. Synthetic policy / intent-contradiction finding
cat << 'EOF' > "${TMP_DIR}/nm-01MTEST002-findings.txt"
id: intent-contradiction-hold-idle
severity: error
file: src/core/daemon.py
line: 108
description: Captain policy specifies hold-until-idle behavior; changing this contradicts stated design intent.
authority: ask-user
EOF

POLICY_OUT="$("${RESOLVER_SH}" "${TMP_DIR}/nm-01MTEST002-findings.txt" --json 2>&1 || true)"
echo "${POLICY_OUT}" | grep -q '"status": "WARNING"' || { echo "FAIL: Expected WARNING for policy finding"; exit 1; }
echo "${POLICY_OUT}" | grep -q '"captain_policy": 1' || { echo "FAIL: Expected captain_policy count 1"; exit 1; }
echo "${POLICY_OUT}" | grep -q 'require_captain_ruling' || { echo "FAIL: Expected require_captain_ruling action"; exit 1; }
echo "PASS: Captain policy finding flagged for supervisor directive"

# 6. Command generation with --resolve-cmds
CMD_OUT="$("${RESOLVER_SH}" "${TMP_DIR}/nm-01MTEST001-findings.txt" --resolve-cmds --child test-worker --json)"
echo "${CMD_OUT}" | grep -q 'bin/fm-send.sh --delivery follow-up --resolve-key nm-01MTEST001-review test-worker' || { echo "FAIL: Expected fm-send resolution command format"; exit 1; }
echo "PASS: Resolution commands generated with canonical fm-send syntax"

echo "=== All 6/6 tests passed successfully ==="
