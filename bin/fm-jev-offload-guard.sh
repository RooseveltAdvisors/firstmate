#!/usr/bin/env bash
# bin/fm-jev-offload-guard.sh - Host Network Generic Receive Offload (GRO) & Hardware Offload Hygiene Guard (Pattern 217)
# Audits Linux network device hardware acceleration and protocol offload features.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/fm-jev-offload-guard.py" "$@"
