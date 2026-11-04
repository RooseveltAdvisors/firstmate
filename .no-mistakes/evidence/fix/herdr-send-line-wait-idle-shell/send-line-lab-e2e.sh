#!/usr/bin/env bash
# Live E2E: fm_backend_herdr_send_text_line against fresh panes in a guarded fm-lab-* Herdr session.
# Usage: send-line-lab-e2e.sh <worktree> <base-herdr.sh> <trials>
set -u
ROOT=$1; BASE=$2; TRIALS=${3:-6}
HELPER="$ROOT/bin/fm-herdr-lab.sh"
REAL_HERDR=$(command -v herdr); ORIG_PATH=$PATH
TMP=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-sendline-e2e.XXXXXX")
mkdir -p "$TMP/fakebin" "$TMP/out"
S=$("$HELPER" name sendline)
export HELPER S REAL_HERDR ORIG_PATH
cleanup() { env PATH="$ORIG_PATH" "$HELPER" teardown "$S"; echo "teardown rc=$?"; rm -rf "$TMP"; }
trap cleanup EXIT
"$HELPER" provision "$S" >/dev/null || { echo provision failed; exit 1; }
cat > "$TMP/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@"); last=$((${#args[@]} - 1)); flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$S" ]; then unset "args[$last]" "args[$flag]"; fi
set -- "${args[@]}"
for a in "$@"; do case "$a" in --session|--session=*) exit 9 ;; esac; done
[ "${1:-}" = --version ] && exec env PATH="$ORIG_PATH" "$REAL_HERDR" "$@" --session "$S"
exec env PATH="$ORIG_PATH" "$HELPER" run "$S" "$@"
SH
chmod +x "$TMP/fakebin/herdr"
lab() { env PATH="$ORIG_PATH" "$HELPER" run "$S" "$@"; }
send() { # <adapter-file> <pane> <text>
  PATH="$TMP/fakebin:$ORIG_PATH" FM_HOME="$TMP" bash -c '. "$1"; fm_backend_herdr_send_text_line "$2:$3" "$4"' _ "$1" "$S" "$2" "$3"
}
now() { python3 -c 'import time;print(time.time())'; }
run_case() { # <label> <adapter> <mode: fresh|nested>
  local label=$1 adapter=$2 mode=$3 ok=0 i ws pane m t0 t1
  for i in $(seq 1 "$TRIALS"); do
    m="$TMP/out/$label.$i"
    ws=$(lab workspace create --cwd "$TMP" --label "$label-$i" --no-focus) || { echo "ws create failed"; continue; }
    pane=$(printf '%s' "$ws" | jq -r '.result.root_pane.pane_id')
    if [ "$mode" = nested ]; then
      sleep 4   # let the top shell settle, then start a nested interactive login shell
      send "$adapter" "$pane" "exec_marker=1 zsh -il" >/dev/null
    fi
    t0=$(now)
    send "$adapter" "$pane" "export FM_E2E_COMPACT=1"
    send "$adapter" "$pane" "printf '%s\n' \"\$FM_E2E_COMPACT\" > '$m'"
    t1=$(now)
    for _ in $(seq 1 100); do [ -s "$m" ] && break; sleep 0.1; done
    if [ "$(cat "$m" 2>/dev/null)" = 1 ]; then ok=$((ok+1)); r=ran; else r=LOST; fi
    printf '%s trial %d: %s (send phase %.2fs)\n' "$label" "$i" "$r" "$(echo "$t1 - $t0" | bc)"
    [ "$r" = LOST ] && { echo "  pane screen tail:"; lab pane read "$pane" --source visible --format text 2>/dev/null | grep -v "^[[:space:]]*$" | tail -4 | sed "s/^/    /"; }
    lab workspace close "$(printf '%s' "$ws" | jq -r '.result.workspace.workspace_id')" >/dev/null 2>&1
  done
  echo "== $label: $ok/$TRIALS ran"
}
for c in ${CASES:-base-fresh fix-fresh base-nested fix-nested}; do
  case $c in base-*) a=$BASE ;; *) a=$ROOT/bin/backends/herdr.sh ;; esac
  run_case "$c" "$a" "${c#*-}"
done
