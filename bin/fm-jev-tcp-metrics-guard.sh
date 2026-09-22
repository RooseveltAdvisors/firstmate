#!/usr/bin/env bash
# bin/fm-jev-tcp-metrics-guard.sh - Host Network TCP Metrics Cache Stale Entry & Metric Bloat Guard (Pattern 216)
# Audits Linux kernel TCP metrics cache and slow start threshold persistence.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/fm-jev-tcp-metrics-guard.py" "$@"
