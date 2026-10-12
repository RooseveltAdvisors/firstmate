#!/usr/bin/env bash
# fm-jev-stale-inbox-guard.sh - Jev Multi-Agent Fleet Worker Inbox Stale Backlog & Dead Endpoint Drain Guard
#
# Usage:
#   fm-jev-stale-inbox-guard.sh [--json] [--dry-run] [--drain-dead] [--max-age-hours N] [--state-dir DIR]
#
# Audits worker inboxes across /opt/ra/firstmate/state/*.inbox, detects unhandled
# messages accumulating on dead or terminated endpoints, and safely archives them
# to eliminate perpetual stack-monitor inbox_stale alerts and supervisor wakes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="$(command -v python3 || command -v python || true)"

if [[ -z "$PYTHON_BIN" ]]; then
  echo "Error: Python 3 interpreter required for fm-jev-stale-inbox-guard." >&2
  exit 1
fi

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-stale-inbox-guard.py" "$@"
