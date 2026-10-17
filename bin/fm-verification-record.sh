#!/usr/bin/env bash
# Record a verification verdict before reporting it. Durable failures are beads,
# separate from the configured tasks-axi dispatch backlog.
# Usage: fm-verification-record.sh --result fail|pass|wontfix
#          --task <owning-task-id> --domain firstmate|fleet-tooling|portal|project
#          --command <failed-command-or-check> --evidence <local-file>
#          [--store <workspace-root>] [--summary <finding>]
# pass and wontfix are no-ops (wontfix is only for cosmetic/theoretical nits).
# Other verdicts require every field. The evidence is snapshotted into the
# selected .beads/verification-evidence before create/update. The dedupe key is
# SHA256(JSON[task, command, realpath(evidence)]), stored as an external_ref.
# Repeats append notes, including a UTC timestamp and a fresh evidence snapshot.
# Closed matches are updated too; this recorder never changes issue status.
# Defaults: firstmate -> FM_HOME; portal -> FM_HOME/projects/portal;
# fleet-tooling -> ~/git/wiseman; project requires --store. FM_VERIFICATION_STORE
# overrides the default root; FM_VERIFICATION_DOMAIN supplies --domain.
# Explicit roots must contain .beads: this script never initializes a store or
# searches a parent. BEADS_DIR is pinned and inherited database overrides cleared.
# bd where must confirm that same directory; a redirect to another store refuses.
# FM_VERIFICATION_BD_BIN selects the Beads CLI (default bd), like the existing
# explicit Beads graph adapter in fm-stale-sweep.sh. Requires jq and python3.
# A store-local mkdir lock serializes list/create/update. Contention or an
# abandoned lock refuses without stealing it; retry after its owner resolves it.
# Output: one JSON receipt {bead, store, evidence, key, action}, only AFTER an
# exact bd list readback. Never infer an ID from create output or task status.
# Any refusal exits nonzero, preserves CLI stderr verbatim, and names the store
# and original three fields for an authorized lane to file. No reply receipt is
# emitted. Evidence snapshots survive a failed write for recovery.
set -euo pipefail
umask 077

usage() { sed -n '2,/^set /{ /^set /d; s/^# \{0,1\}//; p; }' "$0"; }
die() { printf 'fm-verification-record: %s\n' "$*" >&2; exit 1; }
RESULT='' TASK='' FAILED_COMMAND='' EVIDENCE='' SUMMARY=''
DOMAIN=${FM_VERIFICATION_DOMAIN:-}
STORE=${FM_VERIFICATION_STORE:-}
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --result|--task|--domain|--command|--evidence|--store|--summary)
      [ "$#" -ge 2 ] || die "$1 requires a value"
      case "$1" in
        --result) RESULT=$2 ;; --task) TASK=$2 ;; --domain) DOMAIN=$2 ;;
        --command) FAILED_COMMAND=$2 ;; --evidence) EVIDENCE=$2 ;;
        --store) STORE=$2 ;; --summary) SUMMARY=$2 ;;
      esac
      shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$RESULT" in pass|wontfix) exit 0 ;; fail) ;; *) die '--result must be fail, pass or wontfix' ;; esac
[[ "$TASK" =~ ^[a-zA-Z0-9_:\-]+$ ]] || die 'a valid owning --task is required'
[ -n "$FAILED_COMMAND" ] && [ -n "$EVIDENCE" ] || die '--command and --evidence are required'
case "$DOMAIN" in
  firstmate|portal)
    if [ -z "$STORE" ]; then
      [ -n "${FM_HOME:-}" ] || die "$DOMAIN requires FM_HOME or --store"
      STORE=$FM_HOME
      [ "$DOMAIN" != portal ] || STORE="$STORE/projects/portal"
    fi ;;
  fleet-tooling) STORE=${STORE:-$HOME/git/wiseman} ;;
  project) [ -n "$STORE" ] || die 'project requires --store' ;;
  *) die '--domain must be firstmate, fleet-tooling, portal or project' ;;
esac
[ -d "$STORE/.beads" ] || die "selected store does not exist: $STORE/.beads"
STORE=$(cd "$STORE/.beads" && pwd -P)
printf 'fm-verification-record: store=%s task=%s command=%s evidence=%s\n' \
  "$STORE" "$TASK" "$FAILED_COMMAND" "$EVIDENCE" >&2
[ -f "$EVIDENCE" ] && [ -r "$EVIDENCE" ] || die "evidence must be a readable local file: $EVIDENCE"
command -v jq >/dev/null || die 'jq is required'
command -v python3 >/dev/null || die 'python3 is required'
BD_BIN=$(command -v "${FM_VERIFICATION_BD_BIN:-bd}") || die 'Beads CLI is unavailable'
EVIDENCE=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$EVIDENCE")
KEY=$(python3 - "$TASK" "$FAILED_COMMAND" "$EVIDENCE" <<'PY'
import hashlib, json, sys
print(hashlib.sha256(json.dumps(sys.argv[1:], ensure_ascii=True).encode()).hexdigest())
PY
)
REF="fm-verification:$KEY"
LOCK="$STORE/.fm-verification-record.lock"
mkdir "$LOCK" || die "cannot acquire recording lock: $LOCK; no receipt issued, resolve its owner or permissions before retrying"
cleanup() { rmdir "$LOCK" || printf 'fm-verification-record: could not release %s\n' "$LOCK" >&2; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# This is an evidence adapter, never a dispatch/backlog transition.
beads() (
  unset BEADS_DB BEADS_DATABASE BD_DATABASE
  export BEADS_DIR="$STORE"
  cd "$STORE/.." || exit 1
  "$BD_BIN" "$@"
)
list_match() {
  local rows
  rows=$(beads list --all --limit 0 --external-ref "$REF" --json) || return 1
  printf '%s' "$rows" | jq -ce --arg ref "$REF" '
    if type != "array" then error("bd list did not return an array") else
    [.[] | select(.external_ref == $ref)] |
    if length > 1 then error("multiple beads already share the verification key")
    elif length == 0 then {} else .[0] end end'
}
LOCATION=$(beads where --json) || die 'bd where refused; no receipt issued'
ACTUAL_STORE=$(printf '%s' "$LOCATION" | jq -er '.path | select(type == "string" and length > 0)') \
  || die 'bd where did not identify a store'
ACTUAL_STORE=$(cd "$ACTUAL_STORE" && pwd -P) || die 'bd where named an unavailable store'
[ "$ACTUAL_STORE" = "$STORE" ] || die "bd resolved $ACTUAL_STORE instead of selected $STORE; name the actual domain store explicitly"
MATCH=$(list_match) || die 'bd list refused or was invalid; no receipt issued'
ID=$(printf '%s' "$MATCH" | jq -r '.id // empty')
if [ -n "$ID" ]; then
  [[ "$ID" =~ ^[a-zA-Z0-9_:\-]+$ ]] || die 'bd list returned an invalid bead id'
fi
mkdir -p "$STORE/verification-evidence/$KEY"
SNAPSHOT=$(mktemp "$STORE/verification-evidence/$KEY/evidence.XXXXXX")
cp "$EVIDENCE" "$SNAPSHOT"
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NOTE=$(printf 'Recorded (UTC): %s\nOwning task ID: %s\nFailed command: %s\nEvidence path: %s\nAttached evidence: %s\nFinding: %s\n' \
  "$STAMP" "$TASK" "$FAILED_COMMAND" "$EVIDENCE" "$SNAPSHOT" "${SUMMARY:-Verification failed}")
if [ -n "$ID" ]; then
  if ! WRITE_OUTPUT=$(beads update "$ID" --append-notes "$NOTE"); then
    printf '%s\n' "$WRITE_OUTPUT" >&2
    die 'bd update refused; report its output verbatim, no receipt issued'
  fi
  ACTION=updated
else
  if ! WRITE_OUTPUT=$(beads create --title "Verification failure: $TASK" --type bug --priority 2 \
    --external-ref "$REF" --description "$NOTE"); then
    printf '%s\n' "$WRITE_OUTPUT" >&2
    die 'bd create refused; report its output verbatim, no receipt issued'
  fi
  ACTION=created
fi
# Readback is authoritative, including after an ambiguous successful create.
MATCH=$(list_match) || die 'bd list readback failed; retry this same key, never claim it was filed'
CONFIRMED_ID=$(printf '%s' "$MATCH" | jq -r '.id // empty')
[[ "$CONFIRMED_ID" =~ ^[a-zA-Z0-9_:\-]+$ ]] || die 'bd list did not confirm a bead; no receipt issued'
[ -z "$ID" ] || [ "$ID" = "$CONFIRMED_ID" ] || die 'bd list readback changed the bead id'
printf '%s' "$MATCH" | jq -e --arg attachment "$SNAPSHOT" \
  '((.description // "") + "\n" + (.notes // "")) | contains($attachment)' >/dev/null \
  || die 'bd list did not confirm the attached evidence; no receipt issued'
jq -cn --arg bead "$CONFIRMED_ID" --arg store "$STORE" --arg evidence "$SNAPSHOT" \
  --arg key "$KEY" --arg action "$ACTION" \
  '{bead:$bead,store:$store,evidence:$evidence,key:$key,action:$action}'
