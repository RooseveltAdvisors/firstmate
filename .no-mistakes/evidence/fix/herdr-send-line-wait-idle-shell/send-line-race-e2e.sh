#!/usr/bin/env bash
# Live lab E2E for fm_backend_herdr_send_text_line readiness wait.
# Usage: send-line-race-e2e.sh <repo-root> <base-herdr.sh>
set -u
ROOT=$1; BASE_SRC=$2
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name sendline)
TMP=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-sendline.XXXXXX")
mkdir -p "$TMP/fakebin" "$TMP/out"
cleanup() { trap - EXIT; PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; echo "teardown rc=$?"; rm -rf "$TMP"; }
trap cleanup EXIT
cat > "$TMP/fakebin/herdr" <<EOF
#!/usr/bin/env bash
args=("\$@"); n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused" >&2; exit 97; }
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]:0:\$((n-2))}"
EOF
chmod +x "$TMP/fakebin/herdr"
"$LAB_HELPER" provision "$SESSION" || exit 1
echo "lab session: $SESSION"
export PATH="$TMP/fakebin:$ORIGINAL_PATH"
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
# Synthetic rc: busy 1.5s, then tcflush(TCIFLUSH) - drops any typeahead, like a real rc that flushes.
cat > "$TMP/flushrc" <<'EOF'
PS1='lab$ '
sleep 1.5
perl -MPOSIX -e 'POSIX::tcflush(0, POSIX::TCIFLUSH())'
EOF

new_pane() {
  local ws; ws=$(lab workspace create --cwd "$TMP" --label sl --no-focus) || return 1
  WS=$(printf '%s' "$ws" | jq -er '.result.workspace.workspace_id // .result.workspace.id // empty' 2>/dev/null)
  printf '%s' "$ws" | jq -er '.result.root_pane.pane_id'
}
wait_idle_top() { local i=0; while [ $i -lt 100 ]; do fm_backend_herdr_pane_idle_shell_pid "$SESSION" "$1" >/dev/null 2>&1 && return 0; i=$((i+1)); sleep 0.1; done; return 1; }

# trial <impl:fix|base> <mode:top|nested-flush|nested-zsh> <n>
trial() {
  local impl=$1 mode=$2 n=$3 pane out t0 t1 res
  out="$TMP/out/$impl-$mode-$n"
  (
    if [ "$impl" = base ]; then . "$BASE_SRC"; else . "$ROOT/bin/backends/herdr.sh"; fi
    pane=$(new_pane) || { echo "$impl $mode #$n SETUP-FAIL"; exit 0; }
    case $mode in
      nested-flush) wait_idle_top "$pane" || true; lab pane run "$pane" "bash --noprofile --rcfile '$TMP/flushrc' -i" >/dev/null ;;
      nested-zsh)   wait_idle_top "$pane" || true; lab pane run "$pane" "zsh -il" >/dev/null ;;
    esac
    t0=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
    fm_backend_herdr_send_text_line "$SESSION:$pane" "export FM_E2E_X=$n"
    t1=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
    fm_backend_herdr_send_text_line "$SESSION:$pane" "printf 'ok-%s\n' \"\$FM_E2E_X\" > '$out'"
    i=0; while [ $i -lt 80 ] && [ ! -s "$out" ]; do sleep 0.1; i=$((i+1)); done
    if [ "$(cat "$out" 2>/dev/null)" = "ok-$n" ]; then res=PASS; else res=FAIL; fi
    printf '%s %-12s #%-2s %s first-send-wait=%.2fs\n' "$impl" "$mode" "$n" "$res" "$(echo "$t1 - $t0" | bc)"
    if [ $res = FAIL ]; then echo "  --- pane screen ---"; lab pane read "$pane" --source recent --lines 12 2>/dev/null | sed 's/^/  | /'; fi
    [ -n "${WS:-}" ] && lab workspace close "$WS" >/dev/null 2>&1
  )
}

for spec in "base top 6" "fix top 6" "base nested-flush 6" "fix nested-flush 6" "base nested-zsh 6" "fix nested-zsh 18"; do
  set -- $spec
  for n in $(seq 1 "$3"); do trial "$1" "$2" "$n"; done
done

# Bound exhaustion: foreground is busy for 4s; POLLS=5 so the wait gives up fast and still sends.
(
  . "$ROOT/bin/backends/herdr.sh"
  pane=$(new_pane); wait_idle_top "$pane"
  lab pane run "$pane" "sleep 4" >/dev/null; sleep 0.3
  out="$TMP/out/bound"
  t0=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  FM_BACKEND_HERDR_SEND_READY_POLLS=5 fm_backend_herdr_send_text_line "$SESSION:$pane" "echo bound-ok > '$out'"; rc=$?
  t1=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  i=0; while [ $i -lt 80 ] && [ ! -s "$out" ]; do sleep 0.1; i=$((i+1)); done
  printf 'bound-exhaustion POLLS=5 busy-pane: send rc=%s returned-after=%.2fs line-ran=%s\n' "$rc" "$(echo "$t1 - $t0" | bc)" "$(cat "$out" 2>/dev/null || echo NO)"
)
