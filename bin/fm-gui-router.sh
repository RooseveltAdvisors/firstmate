#!/usr/bin/env bash
# fm-gui-router.sh - GUI containment router entrypoint.
#
# SI Control Phase 3: Section 5 GUI Containment.
# Enforces that all agent GUI interactions route through verified automation
# accounts only, refusing personal sessions and unmapped contexts by default.
#
# Adopts bin/fm-gate-refuse-lib.sh: refuses fleet mutation from inside a
# no-mistakes gate context unless running in a marked disposable lab home.
#
# Usage:
#   fm-gui-router.sh check <map_path> <alias> <host>
#   fm-gui-router.sh run <map_path> <alias> <host> [command...]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-gui-guard-lib.sh
. "$SCRIPT_DIR/fm-gui-guard-lib.sh"

# Refuse gate agent lifecycle against real fleet
fm_refuse_if_gate_agent

cmd=${1:-}
map_path=${2:-}
alias=${3:-}
host=${4:-}

case "$cmd" in
  check)
    if [ -z "$map_path" ] || [ -z "$alias" ] || [ -z "$host" ]; then
      echo "usage: fm-gui-router.sh check <map_path> <alias> <host>" >&2
      exit 2
    fi
    if ! fm_gui_guard_check_context "$map_path" "$alias" "$host"; then
      exit 1
    fi
    echo "ok: gui automation context verified for alias $alias on host $host"
    exit 0
    ;;
  run)
    shift 4 2>/dev/null || true
    if [ -z "$map_path" ] || [ -z "$alias" ] || [ -z "$host" ]; then
      echo "usage: fm-gui-router.sh run <map_path> <alias> <host> [command...]" >&2
      exit 2
    fi
    if ! fm_gui_guard_check_context "$map_path" "$alias" "$host"; then
      echo "fm-gui-router: execution refused: context check failed" >&2
      exit 1
    fi
    echo "ok: context verified, launching GUI command"
    if [ $# -gt 0 ]; then
      exec "$@"
    fi
    exit 0
    ;;
  *)
    echo "usage: fm-gui-router.sh check|run <map_path> <alias> <host> [command...]" >&2
    exit 2
    ;;
esac
