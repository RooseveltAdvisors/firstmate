#!/usr/bin/env bash
# bin/fm-jev-ipv6-autoconf-guard.sh - Linux IPv6 Stateless Address Autoconfiguration (SLAAC / RFC 4862) and RFC 4941 Privacy Extensions Guard (Pattern 286 / Pattern 424)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-ipv6-autoconf-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-ipv6-autoconf-guard.py" "$@"
