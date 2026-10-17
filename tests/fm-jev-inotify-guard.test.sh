#!/usr/bin/env bash
# tests/fm-jev-inotify-guard.test.sh - Regression tests for Pattern 40
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-inotify-guard.sh"

echo "Running Pattern 40 regression tests..."

# 1. ShellCheck
shellcheck "$GUARD_SH"
echo "ok - shellcheck clean"

# 2. Help works
"$GUARD_SH" --help >/dev/null
echo "ok - --help works"

# Hold one real inotify watch for the rest of the run so the low-threshold and
# top-consumer cases do not depend on the host already running a watcher.
holder_dir="$(mktemp -d)"
holder_pid=""
cleanup() {
    if [ -n "$holder_pid" ]; then kill "$holder_pid" 2>/dev/null || true; fi
    rm -rf "$holder_dir"
}
trap cleanup EXIT
python3 - "$holder_dir" <<'PY' &
import ctypes, os, sys, time
libc = ctypes.CDLL(None, use_errno=True)
fd = libc.inotify_init()
if fd < 0 or libc.inotify_add_watch(fd, sys.argv[1].encode(), 0x100) < 0:
    sys.exit("inotify setup failed: errno %d" % ctypes.get_errno())
open(os.path.join(sys.argv[1], "ready"), "w").close()
time.sleep(600)
PY
holder_pid=$!
for _ in $(seq 1 100); do
    [ -e "$holder_dir/ready" ] && break
    kill -0 "$holder_pid" 2>/dev/null || { echo "FAILED: inotify holder exited"; exit 1; }
    sleep 0.05
done
[ -e "$holder_dir/ready" ] || { echo "FAILED: inotify holder not ready"; exit 1; }

# 3. JSON format validation
json_out="$("$GUARD_SH" --json)"
echo "$json_out" | python3 -c "
import json, sys
data = json.load(sys.stdin)
assert 'summary' in data
assert 'top_consumers' in data
assert data['summary']['max_user_watches'] > 0
assert data['summary']['total_watches'] >= 0
assert isinstance(data['summary']['healthy'], bool)
"
echo "ok - json schema valid"

# 4. Check mode passes on healthy system
"$GUARD_SH" --check
echo "ok - --check passed cleanly"

# 5. Low warning threshold flags properly
if "$GUARD_SH" --warning-pct 0.0001 --check >/dev/null 2>&1; then
    echo "FAILED: low warning threshold should have exited non-zero"
    exit 1
else
    echo "ok - low warning threshold correctly flags non-zero exit"
fi

# 6. Top consumers properly formatted
top_consumers_len=$(echo "$json_out" | python3 -c "import json, sys; print(len(json.load(sys.stdin)['top_consumers']))")
if [ "$top_consumers_len" -ge 1 ]; then
    echo "ok - top consumers parsed ($top_consumers_len found)"
else
    echo "FAILED: expected at least 1 top consumer"
    exit 1
fi

echo "ok - all Pattern 40 inotify guard tests passed"
