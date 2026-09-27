#!/usr/bin/env bash
# Tear down the lab home and its private tmux server, in the same evidence turn
# that drove the scenarios. Also drops the small pointer files so a rerun mints
# a fresh lab.
set -u
EV=${EV:-/home/jon/.no-mistakes/evidence/01M3G30814BNJEZTBE1P25ZC4J}
LAB=$(cat "$EV/LAB.path" 2>/dev/null || true)
if [ -n "$LAB" ] && [ -d "$LAB" ]; then
  TMUX_TMPDIR="$LAB/tmux" tmux kill-server 2>/dev/null || true
  sleep 0.3
  rm -rf -- "$LAB"
  echo "removed $LAB"
fi
rm -f "$EV/LAB.path" "$EV/FIXTURE_NOW"
echo "teardown done"
