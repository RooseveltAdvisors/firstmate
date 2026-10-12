#!/usr/bin/env bash
# bin/fm-jev-ipv6-neighbor-adv-guard.sh - Linux IPv6 Neighbor Advertisement & Anti-Poisoning Policy Guard (Pattern 290 / Pattern 428)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-ipv6-neighbor-adv-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-ipv6-neighbor-adv-guard.py" "$@"
