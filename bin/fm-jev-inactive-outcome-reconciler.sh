#!/usr/bin/env bash
# fm-jev-inactive-outcome-reconciler.sh - Jev Terminal Inactive-Outcome Auto-Reconciliation & Wake Guard
#
# Usage:
#   fm-jev-inactive-outcome-reconciler.sh [--json] [--dry-run] [--all-done] [--max-age-secs N] [--state-dir DIR]
#
# Audits /opt/ra/firstmate/state/terminal-outcomes/*.pending records produced by
# fm-inactive-reconcile.sh scan. Automatically acknowledges terminal outcomes for
# tasks that have already completed in their status ledgers, preventing spurious
# FIRSTMATE WATCHER WAKE wakeups.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="$(command -v python3 || command -v python || true)"

if [[ -z "$PYTHON_BIN" ]]; then
  echo "Error: Python 3 interpreter required for fm-jev-inactive-outcome-reconciler." >&2
  exit 1
fi

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-inactive-outcome-reconciler.py" "$@"
