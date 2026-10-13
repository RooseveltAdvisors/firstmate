#!/usr/bin/env bash
# fm-deploy-gate.sh - deploy seam gate enforcing denial-on-missing-decision.
#
# SI Control Phase 3: Section 4.5 and Captain Decision 1:
# The DEPLOY seam is the first deny-on-missing-decision action class.
# A present, well-formed, payload-bound, unexpired, one-use allow record is
# required before a deploy action proceeds; anything less DENIES.
#
# Adopts bin/fm-gate-refuse-lib.sh: refuses fleet mutation from inside a
# no-mistakes gate context unless running in a marked disposable lab home.
#
# Usage:
#   fm-deploy-gate.sh check <target> <payload_path> <decision_record_path>
#   fm-deploy-gate.sh execute <target> <payload_path> <decision_record_path> [deploy_cmd...]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-decision-gate-lib.sh
. "$SCRIPT_DIR/fm-decision-gate-lib.sh"

# Refuse gate agent lifecycle against real fleet
fm_refuse_if_gate_agent

cmd=${1:-}
target=${2:-}
payload=${3:-}
decision_record=${4:-}

case "$cmd" in
  check)
    if [ -z "$target" ] || [ -z "$payload" ]; then
      echo "usage: fm-deploy-gate.sh check <target> <payload_path> <decision_record_path>" >&2
      exit 2
    fi
    if ! fm_decision_gate_verify "$decision_record" "deploy" "$target" "$payload"; then
      exit 1
    fi
    echo "ok: deploy decision verified for target $target"
    exit 0
    ;;
  execute)
    shift 4 2>/dev/null || true
    if [ -z "$target" ] || [ -z "$payload" ]; then
      echo "usage: fm-deploy-gate.sh execute <target> <payload_path> <decision_record_path> [cmd...]" >&2
      exit 2
    fi
    if ! fm_decision_gate_verify "$decision_record" "deploy" "$target" "$payload"; then
      echo "fm-deploy-gate: execution refused: decision not allowed" >&2
      exit 1
    fi
    if ! fm_decision_gate_consume "$decision_record"; then
      echo "fm-deploy-gate: execution refused: failed to consume one-use decision record" >&2
      exit 1
    fi
    echo "ok: deploy gate passed, executing deployment to $target"
    if [ $# -gt 0 ]; then
      exec "$@"
    fi
    exit 0
    ;;
  *)
    echo "usage: fm-deploy-gate.sh check|execute <target> <payload_path> <decision_record_path>" >&2
    exit 2
    ;;
esac
