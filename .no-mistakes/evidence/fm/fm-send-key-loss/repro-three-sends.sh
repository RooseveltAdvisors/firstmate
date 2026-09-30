#!/usr/bin/env bash
# Reproduce the reported scenario: three identical sends to one worker, two with
# --resolve-key (keys matching no open decision), one plain. Report exit code,
# stderr, and what durably landed in the worker's inbox for each.
# usage: repro-three-sends.sh <repo-root>
set -u
REPO=$1; SEND="$REPO/bin/fm-send.sh"
T=$(mktemp -d); fb="$T/fakebin"; mkdir -p "$fb" "$T/home/state"; home="$T/home"
cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  send-keys) shift; l=0; while [ $# -gt 0 ]; do case "$1" in -t) shift 2;; -l) l=1; shift;; *) break;; esac; done
    [ $l = 1 ] && printf '%s\n' "${1:-}" >> "$FM_SEND_LOG"; exit 0;;
  display-message) for a in "$@"; do case "$a" in *cursor_y*) echo 1; exit 0;; esac; done; echo fakepane; exit 0;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0;;
  list-windows) echo fm-w1; exit 0;;
esac; exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"; chmod +x "$fb/tmux" "$fb/sleep"
# Same sandbox exemption the repo test suite (tests/lib.sh) exports: temp home + stubbed tmux.
export FM_GATE_REFUSE_BYPASS=1
printf "window=sess:fm-w1\nkind=ship\n" > "$home/state/w1.meta"
printf 'needs-decision [key=real-key]: choose A or B\n' > "$home/state/w1.status"
run() { local label=$1; shift
  : > "$T/log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$T/log" FM_SEND_SETTLE=0 \
    "$SEND" w1 "$@" > "$T/out" 2> "$T/err"; rc=$?
  echo "=== $label: fm-send w1 $*"
  echo "exit=$rc"; echo "stdout: $(cat "$T/out")"; echo "stderr: $(cat "$T/err")"
  echo "doorbell typed: $(tr '\n' ' ' < "$T/log")"
  echo "inbox records now: $(ls "$home/state/w1.inbox" 2>/dev/null | tr '\n' ' ')"
}
run "send 1 (--resolve-key, unmatched)" --resolve-key gate-a "approve the gate decision"
run "send 2 (--resolve-key, unmatched)" --resolve-key gate-b "approve the gate decision"
run "send 3 (no flag)" "approve the gate decision"
echo "=== durable inbox contents"
for f in "$home/state/w1.inbox"/*.msg; do [ -e "$f" ] && { echo "--- $(basename "$f")"; cat "$f"; echo; }; done
echo "=== ledger (w1.status)"; cat "$home/state/w1.status"
rm -rf "$T"
