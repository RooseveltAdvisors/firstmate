#!/usr/bin/env bash
# bin/fm-jev-ipv6-ra-rio-guard.sh - Linux IPv6 Route Information Option (RIO / RFC 4191) & PIO Security Policy Guard (Pattern 291 / Pattern 429)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-ipv6-ra-rio-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-ipv6-ra-rio-guard.py" "$@"
