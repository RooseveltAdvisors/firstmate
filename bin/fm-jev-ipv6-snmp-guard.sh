#!/usr/bin/env bash
# bin/fm-jev-ipv6-snmp-guard.sh - Pattern 221: Host Network IPv6 Protocol Stack (snmp6) Guard wrapper
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${FM_PYTHON_BIN:-python3}"

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-ipv6-snmp-guard.py" "$@"
