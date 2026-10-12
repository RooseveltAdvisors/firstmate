#!/usr/bin/env bash
# bin/fm-jev-netdev-rss-guard.sh - Linux Network Core RSS Key, Per-CPU Headroom & Softnet Guard (Pattern 300 / Pattern 438) - Tercentenary Milestone
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-netdev-rss-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-netdev-rss-guard.py" "$@"
