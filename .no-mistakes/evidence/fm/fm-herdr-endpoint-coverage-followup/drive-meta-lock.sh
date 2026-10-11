#!/usr/bin/env bash
# Drives the real fm-captain-hold.sh reconcile-requests over two captain-held ids
# in a disposable FM_HOME and reports which per-task record locks remain.
set -u
ROOT=$1   # firstmate checkout whose bin/ is exercised
home=$(mktemp -d "${TMPDIR:-/tmp}/fm-metalock.XXXXXX")
mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin"
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
for b in tmux treehouse no-mistakes gh gh-axi; do printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/$b"; chmod +x "$home/fakebin/$b"; done
cap() { PATH="$home/fakebin:$PATH" REAL_TASKS_AXI=$(command -v tasks-axi) FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
  "$ROOT/bin/fm-captain-hold.sh" "$@"; }
cap hold sample-alpha-call --title "Alpha call" --reason "captain decides alpha" --repo sample >/dev/null || exit 9
cap hold sample-beta-call --title "Beta call" --reason "captain decides beta" --repo sample >/dev/null || exit 9
cap bind board-src >/dev/null || exit 9
echo "\$ printf 'sample-alpha-call\nsample-beta-call\n' | fm-captain-hold.sh reconcile-requests --source-id board-src --source 'captured board'"
printf 'sample-alpha-call\nsample-beta-call\n' | cap reconcile-requests --source-id board-src --source "captured board"
echo "exit=$?"
echo "record locks left in state/:"; ls -d "$home"/state/.meta-*.lock 2>/dev/null | sed "s|$home/||" || true
[ -n "$(ls -d "$home"/state/.meta-*.lock 2>/dev/null)" ] && echo "RESULT: LEAKED" || echo "RESULT: CLEAN"
rm -rf "$home"
