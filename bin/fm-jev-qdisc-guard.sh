#!/usr/bin/env bash
# bin/fm-jev-qdisc-guard.sh - Pattern 219: Host Network Traffic Control (tc) Qdisc Backlog Guard wrapper
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${FM_PYTHON_BIN:-python3}"

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-qdisc-guard.py" "$@"
