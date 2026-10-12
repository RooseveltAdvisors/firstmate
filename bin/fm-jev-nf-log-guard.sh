#!/usr/bin/env bash
# bin/fm-jev-nf-log-guard.sh - Host Network Netfilter Logging Backends & Multi-Namespace Isolation Guard (Pattern 282 / Pattern 420)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-nf-log-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-nf-log-guard.py" "$@"
