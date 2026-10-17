#!/usr/bin/env bash
# Record a verification failure before reporting it. Durable failures are beads,
# separate from the configured tasks-axi dispatch backlog.
# Usage: fm-verification-record.sh [--resolve]
#          --task <owning-task-id> --domain firstmate|fleet-tooling|portal|project
#          --command <failed-command-or-check> --evidence <local-file>
#          [--store <workspace-root>] [--summary <finding>]
# Unbracketed fields are required; project also requires --store. The evidence is snapshotted before create/update into
# FM_DATA_OVERRIDE (else FM_HOME/data)/verification-evidence/<key>; without FM
# data it goes to the store's verification-evidence, which ignores itself in git.
# The dedupe key is SHA256(JSON[task, command, realpath(evidence)]), stored as
# an external_ref. Repeats append notes, including a UTC timestamp and a fresh
# evidence snapshot, and reopen a closed match.
# --resolve marks a later pass: it closes an open match of the same key and
# never creates a bead; the evidence file need not exist. Callers never invoke
# the recorder for a pass without a prior recorded failure.
# Defaults: firstmate -> FM_HOME; portal -> FM_HOME/projects/portal;
# fleet-tooling -> ~/git/wiseman; project requires --store. FM_VERIFICATION_STORE
# overrides the default root; FM_VERIFICATION_DOMAIN supplies --domain.
# Explicit roots must contain .beads: this script never initializes a store or
# searches a parent. BEADS_DIR is pinned and inherited database overrides cleared.
# bd where must confirm that same directory; a redirect to another store refuses.
# Requires bd, jq and python3.
# A store-local mkdir lock serializes list/create/update. Contention or an
# abandoned lock refuses without stealing it; retry after its owner resolves it.
# Output: one JSON receipt {bead, store, evidence, key, action}, only AFTER an
# exact bd list readback; --resolve emits {bead, store, key, action:"resolved"}
# only when it closed a bead. Never infer an ID from create output or task status.
# Any refusal exits nonzero, preserves CLI stderr verbatim, and names the store
# and original three fields for an authorized lane to file. No reply receipt is
# emitted. Evidence snapshots survive a failed write for recovery.
set -euo pipefail
umask 077

usage() { sed -n '2,/^set /{ /^set /d; s/^# \{0,1\}//; p; }' "$0"; }
die() { printf 'fm-verification-record: %s\n' "$*" >&2; exit 1; }
RESOLVE='' TASK='' FAILED_COMMAND='' EVIDENCE='' SUMMARY=''
DOMAIN=${FM_VERIFICATION_DOMAIN:-}
STORE=${FM_VERIFICATION_STORE:-}
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --resolve) RESOLVE=1; shift ;;
    --task|--domain|--command|--evidence|--store|--summary)
      [ "$#" -ge 2 ] || die "$1 requires a value"
      case "$1" in
        --task) TASK=$2 ;; --domain) DOMAIN=$2 ;;
        --command) FAILED_COMMAND=$2 ;; --evidence) EVIDENCE=$2 ;;
        --store) STORE=$2 ;; --summary) SUMMARY=$2 ;;
      esac
      shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
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
if [ -z "$RESOLVE" ] && { [ ! -f "$EVIDENCE" ] || [ ! -r "$EVIDENCE" ]; }; then
  die "evidence must be a readable local file: $EVIDENCE"
fi
command -v jq >/dev/null || die 'jq is required'
command -v python3 >/dev/null || die 'python3 is required'
command -v bd >/dev/null || die 'Beads CLI is unavailable'
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
  bd "$@"
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
STATUS=$(printf '%s' "$MATCH" | jq -r '.status // empty')
if [ -n "$RESOLVE" ]; then
  [ -n "$ID" ] && [ "$STATUS" != closed ] || exit 0
  if ! WRITE_OUTPUT=$(beads close "$ID" --reason "Verification passed: $FAILED_COMMAND"); then
    printf '%s\n' "$WRITE_OUTPUT" >&2
    die 'bd close refused; report its output verbatim, the bead stays open'
  fi
  MATCH=$(list_match) || die 'bd list readback failed; never claim the bead was resolved'
  [ "$(printf '%s' "$MATCH" | jq -r '.id // empty')" = "$ID" ] \
    && [ "$(printf '%s' "$MATCH" | jq -r '.status // empty')" = closed ] \
    || die 'bd list did not confirm the bead closed; no receipt issued'
  jq -cn --arg bead "$ID" --arg store "$STORE" --arg key "$KEY" \
    '{bead:$bead,store:$store,key:$key,action:"resolved"}'
  exit 0
fi
DATA=${FM_DATA_OVERRIDE:-${FM_HOME:+$FM_HOME/data}}
if [ -n "$DATA" ]; then
  EVIDENCE_DIR="$DATA/verification-evidence/$KEY"
else
  EVIDENCE_DIR="$STORE/verification-evidence/$KEY"
  mkdir -p "$STORE/verification-evidence"
  printf '*\n' >"$STORE/verification-evidence/.gitignore"
fi
mkdir -p "$EVIDENCE_DIR"
SNAPSHOT=$(mktemp "$EVIDENCE_DIR/evidence.XXXXXX")
cp "$EVIDENCE" "$SNAPSHOT"
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NOTE=$(printf 'Recorded (UTC): %s\nOwning task ID: %s\nFailed command: %s\nEvidence path: %s\nAttached evidence: %s\nFinding: %s\n' \
  "$STAMP" "$TASK" "$FAILED_COMMAND" "$EVIDENCE" "$SNAPSHOT" "${SUMMARY:-Verification failed}")
if [ -n "$ID" ]; then
  REOPEN=()
  [ "$STATUS" != closed ] || REOPEN=(--status open)
  if ! WRITE_OUTPUT=$(beads update "$ID" ${REOPEN[@]+"${REOPEN[@]}"} --append-notes "$NOTE"); then
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
