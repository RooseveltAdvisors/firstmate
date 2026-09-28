#!/usr/bin/env bash
# crew-pane-color-evidence.sh - end-user surface evidence for PR #4358
# (fm/herdr-server-scrub-nocolor).
#
# Demonstrates, against a REAL tmux server on a private socket, what a crew
# pane actually inherits:
#   CONTROL: the pre-fix launch shape - `tmux new-session -d` run directly
#            under a NO_COLOR=1 launcher environment.
#   FIXED:   `fm_backend_tmux_container_ensure` (the adapter this PR changes)
#            run under the same polluted launcher environment.
#
# For each birthed server the script creates a later window (the same
# inheritance every crew window gets) and records
#   (a) that window's environment, and
#   (b) what a NO_COLOR-honoring color-aware CLI (python rich) prints inside it
#       - the visible, end-user consequence: monochrome vs colored output.
set -u

ROOT="${FM_EVIDENCE_ROOT:-/home/jon/.no-mistakes/worktrees/46339c0817e0/01M3K1E3GH6396TV4SYP48KED9}"
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
python3 -c 'import rich' 2>/dev/null || { echo "skip: python 'rich' not installed (color probe)"; exit 0; }

REAL_TMUX=$(command -v tmux)
TAG=$$
CONTROL_SOCK="fm-evidence-control-$TAG"
FIXED_SOCK="fm-evidence-fixed-$TAG"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-evidence.XXXXXX")
SHIM_CTL="$WORK/shim-control"
SHIM_FIX="$WORK/shim-fixed"
mkdir -p "$SHIM_CTL" "$SHIM_FIX"

cleanup() {
  "$REAL_TMUX" -L "$CONTROL_SOCK" kill-server >/dev/null 2>&1 || true
  "$REAL_TMUX" -L "$FIXED_SOCK" kill-server >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$SHIM_CTL/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$CONTROL_SOCK" "\$@"
SH
cat > "$SHIM_FIX/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$FIXED_SOCK" "\$@"
SH
chmod +x "$SHIM_CTL/tmux" "$SHIM_FIX/tmux"

# The color probe a crew pane would run: a NO_COLOR-honoring CLI printing a
# red token. Monochrome output == the launcher's preference bleached the pane.
cat > "$WORK/probe.py" <<'PY'
from rich.console import Console
Console(force_terminal=True, width=40).print("[bold red]RED[/bold red] pane-color-probe")
PY

# The launcher environment an agent/secondmate-started firstmate can carry,
# plus an unrelated variable that must survive the scrub.
pollute() {
  unset TMUX
  export NO_COLOR=1 FORCE_COLOR=0 CLICOLOR=0 CLICOLOR_FORCE=1 FM_LAUNCH_SENTINEL=kept
}

birth() {  # <shim-dir> <mode: control|adapter>
  local shim=$1 mode=$2
  (
    pollute
    export PATH="$shim:$PATH"
    if [ "$mode" = adapter ]; then
      # shellcheck source=/dev/null
      . "$ROOT/bin/fm-backend.sh"
      fm_backend_source tmux
      fm_backend_tmux_container_ensure >/dev/null
    else
      tmux new-session -d -s firstmate   # the pre-fix launch shape
    fi
  )
}

probe_window() {  # <socket> <label>
  local sock=$1 label=$2 out i=0
  out="$WORK/$label"
  "$REAL_TMUX" -L "$sock" new-window -d -t firstmate: \
    "sh -c 'env > $out.env; python3 $WORK/probe.py > $out.color 2>$out.err'" \
    || { echo "could not create probe window on $sock"; return 1; }
  while [ "$i" -lt 100 ]; do
    [ -s "$out.env" ] && [ -s "$out.color" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  echo "probe window on $sock never reported"; return 1
}

echo "=== PR #4358 crew-pane color evidence (real tmux, private sockets) ==="
echo "root: $ROOT"
echo

birth "$SHIM_CTL" control || { echo "control birth failed"; exit 1; }
birth "$SHIM_FIX" adapter  || { echo "adapter birth failed"; exit 1; }
probe_window "$CONTROL_SOCK" control || exit 1
probe_window "$FIXED_SOCK" fixed || exit 1

# Preserve the raw pane output so the reviewer-visible HTML artifact below is
# built from bytes a real crew pane printed, not a transcription.
EV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cp "$WORK/control.color" "$EV_DIR/control-pane-probe.raw"
cp "$WORK/fixed.color" "$EV_DIR/fixed-pane-probe.raw"

report() {  # <file-key> <display-label> <socket>
  local key=$1 label=$2 sock=$3 f="$WORK/$1"
  echo "--- $label"
  echo "    window environment created AFTER the server was born ($sock):"
  grep -E '^(NO_COLOR|FORCE_COLOR|CLICOLOR|CLICOLOR_FORCE|FM_LAUNCH_SENTINEL)=' "$f.env" \
    | sort | sed 's/^/    /'
  echo "    what a NO_COLOR-honoring CLI printed inside that pane (cat -v):"
  sed 's/^/    /' <(cat -v "$f.color")
  echo
}

report control "CONTROL (pre-fix launch shape: tmux new-session under NO_COLOR=1)" "$CONTROL_SOCK"
report fixed    "FIXED (fm_backend_tmux_container_ensure, this PR)" "$FIXED_SOCK"

ctl=$(grep -c '^NO_COLOR=1$' "$WORK/control.env" || true)
fix=$(grep -cE '^(NO_COLOR|FORCE_COLOR|CLICOLOR|CLICOLOR_FORCE)=' "$WORK/fixed.env" || true)
ctl_color=$(grep -c $'\033\[1;31m' "$WORK/control.color" || true)
fix_color=$(grep -c $'\033\[1;31m' "$WORK/fixed.color" || true)

echo "=== summary ==="
[ "$ctl" -eq 1 ] && echo "control pane inherits NO_COLOR=1: leak reproduced" \
                 || { echo "control pane did NOT inherit NO_COLOR - tmux on this host does not propagate it; evidence inconclusive"; exit 1; }
[ "$ctl_color" -eq 0 ] && echo "control pane renders RED monochrome: user-visible bleaching confirmed" \
                        || echo "control pane still rendered color (probe inconclusive)"
[ "$fix" -eq 0 ] && echo "fixed pane inherits none of the four color-control variables: scrub effective" \
                  || { echo "fixed pane still inherited a color-control variable"; exit 1; }
grep -q '^FM_LAUNCH_SENTINEL=kept$' "$WORK/fixed.env" \
  && echo "fixed pane keeps the unrelated FM_LAUNCH_SENTINEL: scrub is narrow" \
  || { echo "fixed pane lost an unrelated launcher variable"; exit 1; }
[ "$fix_color" -eq 1 ] && echo "fixed pane renders RED in color: end-user experience restored" \
                        || echo "fixed pane did not render color (probe inconclusive)"
echo "=== done ==="
