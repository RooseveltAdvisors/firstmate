#!/usr/bin/env bash
# tests/fm-jev-worktree-sync.test.sh - Regression test suite for Pattern 15
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYNC_ENGINE="${FM_ROOT}/bin/fm-jev-worktree-sync.py"

echo "=== Running fm-jev-worktree-sync test suite ==="

# Test 1: Syntax / compilation check
python3 -m py_compile "${SYNC_ENGINE}"
echo "PASS: Test 1 - py_compile syntax valid"

# Test 2: ShellCheck on wrapper
shellcheck "${FM_ROOT}/bin/fm-jev-worktree-sync.sh"
echo "PASS: Test 2 - ShellCheck clean on wrapper"

# Test 3: Unit test git convergence calculation
python3 -c '
import sys
import tempfile
import subprocess
from pathlib import Path
sys.path.insert(0, "'"${FM_ROOT}"'/bin")
import importlib.util
spec = importlib.util.spec_from_file_location("ws", "'"${SYNC_ENGINE}"'")
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)

with tempfile.TemporaryDirectory() as td:
    p = Path(td)
    # Init git repo
    subprocess.run(["git", "init", "-b", "main"], cwd=str(p), check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=str(p), check=True)
    subprocess.run(["git", "config", "user.name", "Test User"], cwd=str(p), check=True)
    
    # Initial commit
    f = p / "README.md"
    f.write_text("# Test Repo\n")
    subprocess.run(["git", "add", "."], cwd=str(p), check=True)
    subprocess.run(["git", "commit", "-m", "initial commit"], cwd=str(p), check=True, stdout=subprocess.DEVNULL)
    
    # Test cleanliness
    res = ws.inspect_worktree(p)
    assert res["is_clean"] is True, "Expected clean worktree"
    branch = res["branch"]
    assert branch == "main", f"Expected main, got {branch}"

print("PASS: Test 3 - Worktree git inspection verified")
'

# Test 4: Live audit on wt-portal-visual-qa
"${FM_ROOT}/bin/fm-jev-worktree-sync.sh" --worktree /home/jon/git/wt-portal-visual-qa
echo "PASS: Test 4 - Live audit on wt-portal-visual-qa verified"

echo "=== All 4/4 fm-jev-worktree-sync tests PASSED (100%) ==="
