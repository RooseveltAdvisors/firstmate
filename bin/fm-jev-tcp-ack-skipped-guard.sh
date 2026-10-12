#!/usr/bin/env bash
# bin/fm-jev-tcp-ack-skipped-guard.sh - Host Network TCP Duplicate ACK Throttling & Skipped ACK Guard (Pattern 229)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-tcp-ack-skipped-guard.py" "$@"
