#!/usr/bin/env bash
# bin/fm-jev-ipv6-hop-limit-guard.sh - Host IPv6 Default Hop Limit & Time Exceeded Guard (Pattern 266 / Pattern 404)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-ipv6-hop-limit-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-ipv6-hop-limit-guard.py" "$@"
