#!/usr/bin/env bash
# Live drive of bin/fm-dispatch-resolve.sh under the registered `jev` fleet
# purpose (agent-vault fleet jev-run), so TYPESAFE_API_KEY is attached on the
# wire by the broker and the resolver makes a REAL typesafe.ai /v1/systemone
# call. quota-axi runs for real from its own cache-format snapshot of today's
# vendor reading (QUOTA_AXI_SNAPSHOT, a documented quota-axi input), so no
# root process writes into the user's cache or credential files.
#
# Usage: drive.sh <label> <resolver-path> <scenario>...
#   scenario = basename of /tmp/fm-live-drive/rules/<scenario>.json
set -u
ROOT_DIR=/tmp/fm-live-drive
EV=/home/jon/.no-mistakes/evidence/01M3GMRT9E4WN389SG879SDEGD
LOG="$EV/live-resolver-drive.log"

label=$1; shift
tool=$1; shift

export HOME="$ROOT_DIR/root-home"
export TMPDIR="$ROOT_DIR/tmp"
export PATH="/home/jon/.npm-global/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export QUOTA_AXI_SNAPSHOT=/home/jon/.cache/quota-axi/quotas.json
mkdir -p "$HOME" "$TMPDIR" "$EV"

{
  echo "===================================================================="
  echo "run: $(date -u +%Y-%m-%dT%H:%M:%SZ)  label=$label  resolver=$tool"
  echo "typesafe key in env: $([ -n "${TYPESAFE_API_KEY:-}" ] && echo yes || echo no)"
  echo "quota source: quota-axi --json with QUOTA_AXI_SNAPSHOT=$QUOTA_AXI_SNAPSHOT"
} >> "$LOG"

for sc in "$@"; do
  cp "$ROOT_DIR/rules/$sc.json" "$ROOT_DIR/home/config/crew-dispatch.json"
  out=$(FM_HOME="$ROOT_DIR/home" timeout 60 "$tool" "$ROOT_DIR/briefs/$sc.md" 2>&1)
  code=$?
  {
    echo "--------------------------------------------------------------------"
    echo "scenario: $sc   exit=$code"
    printf '%s\n' "$out"
    echo
  } >> "$LOG"
done
echo "done: $label"
