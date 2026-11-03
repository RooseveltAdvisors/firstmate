#!/usr/bin/env bash
# Behavior tests for the verified Kimi Code CLI crewmate adapter.
set -u

# shellcheck source=tests/lib.sh
. "{run-worktree}/tests/lib.sh"

# bin/fm-harness.sh answers from environment markers and process ancestry. A
# suite run from inside Cursor, Claude, Pi, or Grok inherits those markers and
# its own real ancestry, either of which can decide a case the detection cases
# meant to control. Drop the ambient markers so the asserted verdict does not
# depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
KIMI_HOOK="$ROOT/bin/fm-kimi-turnend-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-kimi-harness)
KIMI_RUNTIME_TASK_TMP=
KIMI_RUNTIME_LAUNCH_DIR=
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_BIN_DIR=$(dirname "$PYTHON_BIN")
JQ_BIN=$(command -v jq) || fail "test needs jq"
BASE_PATH=${FM_TEST_BASE_PATH:-$PYTHON_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

task_inbox_export() {  # <home> <id>
  local state
  state=$(CDPATH='' cd -- "$1/state" && pwd -P) || fail "cannot resolve state dir $1/state"
  printf "export FM_TASK_INBOX='%s'; " "$state/$2.inbox"
}

fm_home_export() {  # <home>
  printf "export FM_HOME='%s'; " "$1"
}


cleanup_kimi_harness() {
  [ -z "$KIMI_RUNTIME_TASK_TMP" ] || fm_test_remove_tree "$KIMI_RUNTIME_TASK_TMP"
  [ -z "$KIMI_RUNTIME_LAUNCH_DIR" ] || fm_test_remove_tree "$KIMI_RUNTIME_LAUNCH_DIR"
  fm_test_remove_tree "$TMP_ROOT"
}
trap cleanup_kimi_harness EXIT

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_KIMI_STATE" 2>/dev/null || true)
fake_screen() {
  case "$state" in
    ready)
      printf 'Welcome to Kimi Code!\ncontext: 0%% (0/256k)\n╭────────────────────────────────╮\n│ >                              │\n╰────────────────────────────────╯\n'
      ;;
    trust)
      printf '╭─ Trust this folder? ─╮\n│ ↑↓ navigate · Enter select · Esc exit │\n│ %s │\n│ ❯ Trust this folder │\n│   Don'"'"'t trust │\n╰──────────────────────────────╯\n' "$FM_FAKE_PANE_PATH"
      ;;
    trust-decoy)
      printf 'Trust this folder?\n%s\n❯ Trust this folder\nDon'"'"'t trust\n' "$FM_FAKE_PANE_PATH"
      ;;
    trust-partial)
      printf 'Welcome to Kimi Code!\nTrust this folder?\n%s\nDon'"'"'t trust\n' "$FM_FAKE_PANE_PATH"
      ;;
    booting)
      printf 'shell starting\n$ \n'
      ;;
    banner-only|banner-first)
      printf 'Welcome to Kimi Code!\nstarting in %s\n' "$FM_FAKE_PANE_PATH"
      ;;
    blank-frame)
      ;;
    trust-wrapped)
      printf '╭─ Trust this folder? ─╮\n│ ↑↓ navigate ·        │\n│ Enter select · Esc   │\n│ exit                 │\n│ %s │\n│ ❯ Trust this folder  │\n│   Don'"'"'t trust         │\n╰──────────────────────╯\n' "$FM_FAKE_PANE_PATH"
      ;;
    trust-211-rootmcp)
      sed "s|{WORKDIR}|$FM_FAKE_PANE_PATH|g" "$FM_FAKE_KIMI_CAPTURES/root-mcp-json.pane"
      ;;
    trust-211-plain)
      sed "s|{WORKDIR}|$FM_FAKE_PANE_PATH|g" "$FM_FAKE_KIMI_CAPTURES/plain-211.pane"
      ;;
    trust-230|trust-230-rootmcp|trust-230-kimimcp|trust-230-small|trust-230-paged)
      # Recorded from Kimi Code CLI 2.3.0; tests/captures/kimi-code-2.3.0/README.md
      # owns the provenance. The directory line becomes the fake pane's path.
      case "$state" in
        trust-230) capture=plain.pane ;;
        trust-230-rootmcp) capture=root-mcp-json.pane ;;
        trust-230-kimimcp) capture=kimi-code-mcp-json.pane ;;
        trust-230-small) capture=small-terminal.pane ;;
        trust-230-paged) capture=paged.pane ;;
      esac
      sed "s|{WORKDIR}|$FM_FAKE_PANE_PATH|g" "$FM_FAKE_KIMI_CAPTURES/$capture"
      ;;
    pointer-typed)
      printf 'context: 0%% (0/256k)\n╭────────────────────────────────╮\n│ > Read the brief and follow it │\n│                                │\n╰────────────────────────────────╯\n'
      ;;
    delivered)
      printf '✨ Read the brief at %s and follow it exactly.\ncontext: 1%% (2k/256k)\n╭────────────────────────────────╮\n│ >                              │\n╰────────────────────────────────╯\n' "$FM_FAKE_BRIEF_REAL"
      ;;
    *)
      printf 'shell starting\n$ \n'
      ;;
  esac
}
fake_history() {
  if [ "${FM_FAKE_KIMI_HISTORY_KEEPS_DIALOG:-no}" = yes ] \
     && [ -s "$FM_FAKE_KIMI_TRUST_ENTER_LOG" ]; then
    printf '╭─ Trust this folder? ─╮\n│ ↑↓ navigate · Enter select · Esc exit │\n│ ❯ Trust this folder │\n│   Don'"'"'t trust │\n╰──────────────────────╯\n'
  fi
}
fake_cursor_y() {
  case "$state" in
    pointer-typed) printf '3\n' ;;
    ready|delivered) printf '3\n' ;;
    *) printf '1\n' ;;
  esac
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) fake_cursor_y; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ ! -s "$FM_FAKE_KIMI_STATE.window" ] || cat "$FM_FAKE_KIMI_STATE.window"
    exit 0 ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" > "$FM_FAKE_KIMI_STATE.window"
    exit 0 ;;
  kill-window) : > "$FM_FAKE_KIMI_STATE.window"; exit 0 ;;
  has-session|new-session) exit 0 ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        ". '"*"'") staged=${literal#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || literal=$(cat "$staged") ;;
      esac
      case "$literal" in
        *' --auto')
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'launched\n' > "$FM_FAKE_KIMI_STATE"
          ;;
        *)
          printf '%s\n' "$literal" >> "$FM_FAKE_POINTER_LOG"
          case "$state" in
            trust|trust-wrapped|trust-partial|trust-decoy|trust-211-rootmcp|trust-211-plain|trust-230|trust-230-rootmcp|trust-230-kimimcp|trust-230-small|trust-230-paged|booting|banner-only|banner-first|blank-frame) ;;
            *) printf 'pointer-typed\n' > "$FM_FAKE_KIMI_STATE" ;;
          esac
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launched)
            if [ "${FM_FAKE_KIMI_READY:-yes}" = yes ]; then
              case "${FM_FAKE_KIMI_TRUST:-remembered}" in
                fresh) printf 'trust\n' > "$FM_FAKE_KIMI_STATE" ;;
                decoy) printf 'trust-decoy\n' > "$FM_FAKE_KIMI_STATE" ;;
                partial) printf 'trust-partial\n' > "$FM_FAKE_KIMI_STATE" ;;
                late) printf 'booting\n' > "$FM_FAKE_KIMI_STATE" ;;
                blink) printf 'banner-first\n' > "$FM_FAKE_KIMI_STATE" ;;
                wrapped) printf 'trust-wrapped\n' > "$FM_FAKE_KIMI_STATE" ;;
                211-rootmcp) printf 'trust-211-rootmcp\n' > "$FM_FAKE_KIMI_STATE" ;;
                211-plain) printf 'trust-211-plain\n' > "$FM_FAKE_KIMI_STATE" ;;
                230) printf 'trust-230\n' > "$FM_FAKE_KIMI_STATE" ;;
                230-rootmcp) printf 'trust-230-rootmcp\n' > "$FM_FAKE_KIMI_STATE" ;;
                230-kimimcp) printf 'trust-230-kimimcp\n' > "$FM_FAKE_KIMI_STATE" ;;
                230-small) printf 'trust-230-small\n' > "$FM_FAKE_KIMI_STATE" ;;
                230-paged) printf 'trust-230-paged\n' > "$FM_FAKE_KIMI_STATE" ;;
                *) printf 'ready\n' > "$FM_FAKE_KIMI_STATE" ;;
              esac
            fi
            ;;
          trust|trust-wrapped|trust-211-plain|trust-230)
            printf 'enter\n' >> "$FM_FAKE_KIMI_TRUST_ENTER_LOG"
            trust_enters=$(wc -l < "$FM_FAKE_KIMI_TRUST_ENTER_LOG" | tr -d ' ')
            case "${FM_FAKE_KIMI_TRUST_CLEARS:-yes}" in
              yes) printf 'ready\n' > "$FM_FAKE_KIMI_STATE" ;;
              after-second)
                [ "$trust_enters" -lt 2 ] || printf 'ready\n' > "$FM_FAKE_KIMI_STATE"
                ;;
            esac
            ;;
          trust-211-rootmcp|trust-230-rootmcp|trust-230-kimimcp|trust-230-paged)
            # Observed live on Kimi 2.3.0: Enter on a prompt that announces
            # project servers starts the declared command before any login,
            # and the paged prompt is that same prompt with the announcement
            # on a page that is not shown.
            printf 'enter\n' >> "$FM_FAKE_KIMI_TRUST_ENTER_LOG"
            printf 'started-by-fake-kimi\n' >> "$FM_FAKE_MCP_MARKER_LOG"
            printf 'ready\n' > "$FM_FAKE_KIMI_STATE"
            ;;
          trust-230-small)
            printf 'enter\n' >> "$FM_FAKE_KIMI_TRUST_ENTER_LOG"
            ;;
          ready|delivered)
            printf 'enter\n' >> "$FM_FAKE_KIMI_STRAY_ENTER_LOG"
            ;;
          pointer-typed)
            if [ "${FM_FAKE_KIMI_DELIVERY:-yes}" = yes ]; then
              if [ "${FM_FAKE_KIMI_SWALLOW_FIRST:-no}" = yes ] \
                 && [ ! -f "$FM_FAKE_KIMI_SWALLOWED" ]; then
                : > "$FM_FAKE_KIMI_SWALLOWED"
              else
                printf 'delivered\n' > "$FM_FAKE_KIMI_STATE"
              fi
            else
              printf 'ready\n' > "$FM_FAKE_KIMI_STATE"
            fi
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    start= end= prev=
    for arg in "$@"; do
      case "$prev" in
        -S) start=$arg ;;
        -E) end=$arg ;;
      esac
      case "$arg" in -S|-E) prev=$arg ;; *) prev= ;; esac
    done
    if [ "$start" = -0 ] && [ "${FM_FAKE_TMUX_VISIBLE_FAILS:-no}" = yes ]; then
      echo "can't find pane" >&2
      exit 1
    fi
    case "$start" in
      -0|-120)
        case "$state" in
          booting) printf 'banner-only\n' > "$FM_FAKE_KIMI_STATE" ;;
          banner-first) printf 'blank-frame\n' > "$FM_FAKE_KIMI_STATE" ;;
          blank-frame) printf 'banner-only\n' > "$FM_FAKE_KIMI_STATE" ;;
          banner-only) printf 'trust\n' > "$FM_FAKE_KIMI_STATE" ;;
        esac
        ;;
    esac
    if [ "$start" = -0 ] && [ "${FM_FAKE_KIMI_BLANK_AFTER_TRUST:-no}" = yes ] \
       && [ -s "$FM_FAKE_KIMI_TRUST_ENTER_LOG" ] && [ ! -f "$FM_FAKE_KIMI_BLANKED" ]; then
      : > "$FM_FAKE_KIMI_BLANKED"
      exit 0
    fi
    [ "$start" != -120 ] || fake_history
    case "$start:$end" in
      *[!0-9:]*|'':*|*:'') fake_screen ;;
      *) fake_screen | awk -v start="$start" -v end="$end" \
           'NR - 1 >= start && NR - 1 <= end' ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  fm_fake_exit0 "$fakebin" kimi
  ln -s "$JQ_BIN" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$home/.kimi-code"
  printf '# Kimi test config\ndefault_model = "test"\n' > "$home/.kimi-code/config.toml"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Kimi dispatch.

## Firstmate spec
Verify launch and delivery behavior.
EOF
  printf 'kimi\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/pointer.log"
  : > "$case_dir/kimi.state"
  : > "$case_dir/trust-enter.log"
  : > "$case_dir/stray-enter.log"
  : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_POINTER_LOG="$case_dir/pointer.log" \
    FM_FAKE_KIMI_STATE="$case_dir/kimi.state" \
    FM_FAKE_KIMI_TRUST_ENTER_LOG="$case_dir/trust-enter.log" \
    FM_FAKE_KIMI_TRUST="${FM_FAKE_KIMI_TRUST:-remembered}" \
    FM_FAKE_KIMI_TRUST_CLEARS="${FM_FAKE_KIMI_TRUST_CLEARS:-yes}" \
    FM_FAKE_KIMI_HISTORY_KEEPS_DIALOG="${FM_FAKE_KIMI_HISTORY_KEEPS_DIALOG:-no}" \
    FM_FAKE_KIMI_STRAY_ENTER_LOG="$case_dir/stray-enter.log" \
    FM_FAKE_KIMI_BLANK_AFTER_TRUST="${FM_FAKE_KIMI_BLANK_AFTER_TRUST:-no}" \
    FM_FAKE_KIMI_BLANKED="$case_dir/kimi.blanked" \
    FM_FAKE_TMUX_VISIBLE_FAILS="${FM_FAKE_TMUX_VISIBLE_FAILS:-no}" \
    FM_FAKE_KIMI_SWALLOWED="$case_dir/kimi.swallowed" \
    FM_FAKE_KIMI_SWALLOW_FIRST="${FM_FAKE_KIMI_SWALLOW_FIRST:-no}" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_KIMI_CAPTURES="${DRIVER_CAPTURES:-$ROOT/tests/captures/kimi-code-2.3.0}" \
    FM_FAKE_MCP_MARKER_LOG="$case_dir/marker.log" \
    FM_FAKE_BRIEF_REAL="$(cd "$home/data/$id" && pwd -P)/launch-brief.md" \
    FM_KIMI_READY_POLLS="${FM_KIMI_READY_POLLS:-2}" FM_KIMI_DELIVERY_POLLS=2 FM_KIMI_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness kimi --mode no-mistakes --yolo off "$@" 2>&1
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

