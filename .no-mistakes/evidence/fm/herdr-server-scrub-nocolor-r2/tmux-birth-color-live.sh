#!/usr/bin/env bash
# Live scenario driver: tmux server-birth color scrub (PR NO_COLOR/herdr server scrub).
# Drives bin/backends/tmux.sh's fm_backend_tmux_container_ensure against REAL tmux
# servers on private sockets (TMUX_TMPDIR), never the host's default server.
set -u

ROOT="/home/jon/.no-mistakes/worktrees/2f32188048b1/01M3XCMC6EC0Q9PGX9F3PP45XN"
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-color-tmux.XXXXXX")
# tmux silently IGNORES TMUX_TMPDIR when the directory does not exist and falls
# back to the host default socket, so the private socket dirs must exist first.
mkdir -p "$T/ctl" "$T/fixed"
cleanup() {
  TMUX_TMPDIR="$T/ctl" tmux kill-server >/dev/null 2>&1 || true
  TMUX_TMPDIR="$T/fixed" tmux kill-server >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT

probe_window_env() { # <socket-dir> <outfile>
  local dir=$1 out=$2 i=0
  env -u NO_COLOR -u FORCE_COLOR -u CLICOLOR -u CLICOLOR_FORCE \
    TMUX_TMPDIR="$dir" tmux new-window -d -t firstmate: "env > '$out'"
  while [ "$i" -lt 100 ]; do
    [ -s "$out" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  echo "PROBE NEVER REPORTED: $out" >&2
  return 1
}

echo "== scenario: control - an UNSCRUBBED server birth really leaks color control =="
# Assert isolation BEFORE anything touches a socket.
for d in ctl fixed; do
  p=$(TMUX_TMPDIR="$T/$d" tmux display-message -p '#{socket_path}' 2>&1) || true
  case "$p" in
    *"$T/$d"/*) echo "isolated socket ($d): $p" ;;
    *) echo "FAIL: tmux did not honor the private TMUX_TMPDIR for $d (got: $p)"; exit 1 ;;
  esac
done
env -u TMUX NO_COLOR=1 FORCE_COLOR=0 CLICOLOR=0 CLICOLOR_FORCE=1 FM_TMUX_LAUNCH_SENTINEL=kept \
  TMUX_TMPDIR="$T/ctl" tmux new-session -d -s firstmate
probe_window_env "$T/ctl" "$T/control-env.txt"
grep -E '^(NO_COLOR|FORCE_COLOR|CLICOLOR|CLICOLOR_FORCE|FM_TMUX_LAUNCH_SENTINEL)=' "$T/control-env.txt" | sort | sed 's/^/control-window: /'

echo "== scenario: firstmate container_ensure births the server WITHOUT color control =="
fixed_out=$(
  env -u TMUX NO_COLOR=1 FORCE_COLOR=0 CLICOLOR=0 CLICOLOR_FORCE=1 FM_TMUX_LAUNCH_SENTINEL=kept \
    TMUX_TMPDIR="$T/fixed" HOME="$T" bash -c '
      set -u
      . "$1/bin/fm-backend.sh"
      fm_backend_source tmux || exit 1
      fm_backend_tmux_container_ensure
    ' _ "$ROOT"
) || { echo "FAIL: container_ensure errored"; exit 1; }
echo "container_ensure echoed: $fixed_out"
probe_window_env "$T/fixed" "$T/fixed-env.txt"
grep -E '^(NO_COLOR|FORCE_COLOR|CLICOLOR|CLICOLOR_FORCE|FM_TMUX_LAUNCH_SENTINEL)=' "$T/fixed-env.txt" | sort | sed 's/^/first-window: /'

fail=0
for n in NO_COLOR FORCE_COLOR CLICOLOR CLICOLOR_FORCE; do
  if grep -q "^$n=" "$T/fixed-env.txt"; then echo "FAIL: $n leaked into the birthed server"; fail=1; fi
done
grep -q '^FM_TMUX_LAUNCH_SENTINEL=kept' "$T/fixed-env.txt" || { echo "FAIL: unrelated sentinel lost"; fail=1; }
grep -q '^NO_COLOR=1' "$T/control-env.txt" || { echo "FAIL: control did not leak - inheritance unproven here"; fail=1; }
[ "$fixed_out" = firstmate ] || { echo "FAIL: expected session name firstmate"; fail=1; }

echo "== adversarial: a SECOND container_ensure under a polluted env must not inject into the running server =="
reuse_out=$(
  env -u TMUX NO_COLOR=1 FORCE_COLOR=0 CLICOLOR=0 CLICOLOR_FORCE=1 FM_TMUX_LAUNCH_SENTINEL=kept \
    TMUX_TMPDIR="$T/fixed" HOME="$T" bash -c '
      set -u
      . "$1/bin/fm-backend.sh"
      fm_backend_source tmux || exit 1
      fm_backend_tmux_container_ensure
    ' _ "$ROOT"
) || { echo "FAIL: reuse container_ensure errored"; fail=1; }
echo "reuse container_ensure echoed: $reuse_out"
probe_window_env "$T/fixed" "$T/reuse-env.txt"
grep -E '^(NO_COLOR|FORCE_COLOR|CLICOLOR|CLICOLOR_FORCE|FM_TMUX_LAUNCH_SENTINEL)=' "$T/reuse-env.txt" | sort | sed 's/^/post-reuse-window: /'
for n in NO_COLOR FORCE_COLOR CLICOLOR CLICOLOR_FORCE; do
  if grep -q "^$n=" "$T/reuse-env.txt"; then echo "FAIL: reuse path injected $n into the running server"; fail=1; fi
done
grep -q '^FM_TMUX_LAUNCH_SENTINEL=kept' "$T/reuse-env.txt" || { echo "FAIL: sentinel lost after reuse"; fail=1; }
[ "$reuse_out" = firstmate ] || { echo "FAIL: reuse should echo firstmate"; fail=1; }

if [ "$fail" -eq 0 ]; then echo "ALL TMUX BIRTH-ENV CHECKS PASSED"; else echo "TMUX BIRTH-ENV CHECKS FAILED"; fi
exit "$fail"
