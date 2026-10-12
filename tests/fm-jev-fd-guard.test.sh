#!/usr/bin/env bash
# tests/fm-jev-fd-guard.test.sh - Test suite for Pattern 36 Host File Descriptor Guard
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
GUARD_SH="$FM_ROOT/bin/fm-jev-fd-guard.sh"

pass() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

# 1. ShellCheck validation
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$GUARD_SH" || fail "shellcheck failed on fm-jev-fd-guard.sh"
  pass "shellcheck clean"
else
  echo "skip: shellcheck not found"
fi

# 2. Help flag verification
"$GUARD_SH" --help >/dev/null 2>&1 || fail "--help failed"
pass "--help works"

# 3. JSON schema verification
json_out=$("$GUARD_SH" --json)
[ -n "$json_out" ] || fail "empty json output"

healthy=$(echo "$json_out" | jq -r '.healthy')
[ "$healthy" = "true" ] || [ "$healthy" = "false" ] || fail "unexpected healthy boolean: $healthy"
pass "healthy field is valid boolean ($healthy)"

audited=$(echo "$json_out" | jq -r '.audited_processes_count')
[ "$audited" -gt 0 ] || fail "expected at least 1 audited process"
pass "audited_processes_count is positive ($audited)"

total_fds=$(echo "$json_out" | jq -r '.total_user_open_fds')
[ "$total_fds" -gt 0 ] || fail "expected at least 1 open fd"
pass "total_user_open_fds is positive ($total_fds)"

# 4. Normal check mode
"$GUARD_SH" --check || fail "expected check to pass on healthy host"
pass "--check passed cleanly"

# 5. Low threshold verification
warn_out=$("$GUARD_SH" --warn-count 5 --json)
warn_count=$(echo "$warn_out" | jq -r '.flagged_processes_count')
[ "$warn_count" -gt 0 ] || fail "expected flagged processes with artificially low warn-count"
pass "low threshold correctly flags heavy processes ($warn_count flagged)"

pass "all Pattern 36 host file descriptor guard tests passed"
