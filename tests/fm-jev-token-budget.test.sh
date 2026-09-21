#!/usr/bin/env bash
# tests/fm-jev-token-budget.test.sh - Regression test suite for Pattern 16
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUDGET_ENGINE="${FM_ROOT}/bin/fm-jev-token-budget.py"

echo "=== Running fm-jev-token-budget test suite ==="

# Test 1: Syntax / compilation check
python3 -m py_compile "${BUDGET_ENGINE}"
echo "PASS: Test 1 - py_compile syntax valid"

# Test 2: ShellCheck on wrapper
shellcheck "${FM_ROOT}/bin/fm-jev-token-budget.sh"
echo "PASS: Test 2 - ShellCheck clean on wrapper"

# Test 3: Unit test token calculation, frontmatter parsing, and section breakdown
python3 -c '
import sys
import tempfile
from pathlib import Path
sys.path.insert(0, "'"${FM_ROOT}"'/bin")
import importlib.util
spec = importlib.util.spec_from_file_location("tb", "'"${BUDGET_ENGINE}"'")
tb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tb)

# 1. Test calculate_tokens
text = "A" * 100
assert tb.calculate_tokens(text) == 25, f"Expected 25 tokens for 100 bytes, got {tb.calculate_tokens(text)}"

# 2. Test section analysis
md_content = """# Preamble Section
Some intro lines here.

## Core Rules
- Rule 1
- Rule 2

## Operations Runbook
Detailed operations here.
"""
sections = tb.analyze_sections(md_content)
assert len(sections) == 3, f"Expected 3 sections, got {len(sections)}"
assert sections[0]["title"] == "Preamble Section"
assert sections[1]["title"] == "Core Rules"
assert sections[2]["title"] == "Operations Runbook"

# 3. Test skill frontmatter parsing
with tempfile.TemporaryDirectory() as td:
    skill_file = Path(td) / "SKILL.md"
    skill_file.write_text("""---
name: sample-skill
description: Comprehensive guide for testing skills.
---
# Skill Body
""")
    fm = tb.parse_skill_frontmatter(skill_file)
    assert fm["name"] == "sample-skill"
    assert "Comprehensive guide" in fm["description"]
    assert fm["tokens"] > 0

print("PASS: Test 3 - Unit tests verified")
'

# Test 4: Live audit on compliant repository (wt-uiq-fk)
"${FM_ROOT}/bin/fm-jev-token-budget.sh" --repo-path /home/jon/git/wt-uiq-fk
echo "PASS: Test 4 - Live audit on wt-uiq-fk verified compliant"

# Test 5: JSON schema and output validation
"${FM_ROOT}/bin/fm-jev-token-budget.sh" --repo-path /home/jon/git/wt-uiq-fk --json | grep -q '"status": "COMPLIANT"'
echo "PASS: Test 5 - JSON output verified"

echo "=== All 5/5 fm-jev-token-budget tests PASSED (100%) ==="
