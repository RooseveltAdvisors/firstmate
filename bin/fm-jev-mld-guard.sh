#!/usr/bin/env bash
# bin/fm-jev-mld-guard.sh - Host IPv6 Multicast Listener Discovery (MLD / RFC 3810 / RFC 2710) Guard (Pattern 263 / Pattern 401)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-mld-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-mld-guard.py" "$@"
