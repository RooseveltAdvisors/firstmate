#!/usr/bin/env bash
# tests/fm-jev-stall-guard.test.sh - Regression test suite for Pattern 14
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GUARD="${FM_ROOT}/bin/fm-jev-stall-guard.py"

echo "=== Running fm-jev-stall-guard test suite ==="

# Test 1: Syntax / compilation check
python3 -m py_compile "${GUARD}"
echo "PASS: Test 1 - py_compile syntax valid"

# Test 2: ShellCheck on wrapper
shellcheck "${FM_ROOT}/bin/fm-jev-stall-guard.sh"
echo "PASS: Test 2 - ShellCheck clean on wrapper"

# Test 3: Unit test activity evaluation logic
python3 -c '
import sys
import tempfile
import time
from pathlib import Path
sys.path.insert(0, "'"${FM_ROOT}"'/bin")
import importlib.util
spec = importlib.util.spec_from_file_location("sg", "'"${GUARD}"'")
sg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sg)

# Case 1: Active worktree with fresh file modification
with tempfile.TemporaryDirectory() as td:
    p = Path(td)
    test_file = p / "test.txt"
    test_file.write_text("active code")
    recent = sg.check_worktree_mtime(p, max_age_seconds=60)
    assert len(recent) == 1, f"Expected 1 recent file, got {recent}"

    # Case 2: Stale worktree (mtime simulated in past)
    old_time = time.time() - 1000
    import os
    os.utime(test_file, (old_time, old_time))
    stale = sg.check_worktree_mtime(p, max_age_seconds=60)
    assert len(stale) == 0, f"Expected 0 recent files, got {stale}"

print("PASS: Test 3 - Worktree mtime prober verified")
'

# Test 4: The observer cannot suppress its own stall, while a real worker can.
python3 - "$FM_ROOT/bin/fm-jev-stall-guard.sh" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

guard = sys.argv[1]
seat = "fm-idle-" + uuid.uuid4().hex
with tempfile.TemporaryDirectory() as td:
    env = dict(os.environ, HOME=td, FM_HOME=td)
    import shutil
    python_guard = Path(guard).with_suffix(".py")
    renamed = Path(td) / "observer.py"
    shutil.copyfile(python_guard, renamed)
    invocations = [
        [guard],
        ["bash", guard],
        [sys.executable, str(python_guard)],
        ["env", "python3", str(python_guard)],
        [sys.executable, str(renamed)],
    ]
    def probe(command):
        return subprocess.run(
            command + ["--seat", seat, "--suppress", "--json"],
            env=env, capture_output=True, text=True, check=False,
        )
    for command in invocations:
        idle = probe(command)
        result = json.loads(idle.stdout)
        assert idle.returncode == 1, (command, idle.stdout, idle.stderr)
        assert result["signals"]["active_processes"] == [], result
        assert result["verdict"] == "GENUINE_STALL", result

    print("PASS: idle CLI invocations: wrapper, bash wrapper, python, env python, renamed observer")

    ready = Path(td) / "ready"
    worker = subprocess.Popen([
        sys.executable, "-c",
        "import pathlib,sys,time; pathlib.Path(sys.argv[1]).touch(); time.sleep(60)",
        str(ready), seat,
    ])
    try:
        import time
        for _ in range(200):
            if ready.exists():
                break
            time.sleep(0.01)
        assert ready.exists(), "worker never started"
        for command in invocations:
            busy = probe(command)
            result = json.loads(busy.stdout)
            assert busy.returncode == 0, (command, busy.stdout, busy.stderr)
            processes = result["signals"]["active_processes"]
            assert any(p.split()[0] == str(worker.pid) for p in processes), result
            assert all("fm-jev-stall-guard.py" not in p for p in processes), result
        print("PASS: every CLI invocation detects the real worker PID")
    finally:
        worker.terminate()
        worker.wait(timeout=5)
    for command in invocations:
        assert probe(command).returncode == 1, "ended worker still suppressed the stall"

    print("PASS: every CLI invocation reports a stall after worker exit")

    # A ps snapshot is an external protocol: concurrent observers may be
    # rendered as interpreter, shell, or proxy-carried command arguments.
    # None is worker activity, even when it is a different process.
    fakebin = Path(td) / "fakebin"
    fakebin.mkdir()
    rows = [
        f"20001 python3 {python_guard} --seat {seat}",
        f"20002 bash {guard} --seat {seat}",
        f"20003 bash -c \"python3 {python_guard} --seat {seat}\"",
        f"20004 bash /opt/ra/infisical/bin/jev-proxy.sh --data-binary \"{python_guard} --seat {seat}\"",
    ]
    ps = fakebin / "ps"
    ps.write_text("#!/usr/bin/env python3\n" + "print(" + repr("\n".join(rows)) + ")\n")
    ps.chmod(0o755)
    env["PATH"] = str(fakebin) + os.pathsep + os.environ["PATH"]
    for command in invocations:
        idle = probe(command)
        result = json.loads(idle.stdout)
        assert idle.returncode == 1, (command, idle.stdout, idle.stderr)
        assert result["signals"]["active_processes"] == [], result
    print("PASS: concurrent interpreter, shell, shell-command and proxy-carried observers cannot suppress a stall")
PY
echo "PASS: Test 4 - Idle probe and real worker activity distinguished"

echo "=== All 4/4 fm-jev-stall-guard tests PASSED (100%) ==="
