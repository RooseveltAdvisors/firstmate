#!/usr/bin/env bash
# Capture the end-user session-start digest produced against a wedged backlog
# backend: bin/fm-session-start.sh must complete with every digest section
# present and a loud partial reconcile naming the item it could not read.
set -u

ROOT=/home/jon/.no-mistakes/worktrees/46339c0817e0/01M219PH5PH1ZDA571GPZXBHXM
EV=/home/jon/.no-mistakes/evidence/01M219PH5PH1ZDA571GPZXBHXM
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
BOUND_SECS=2

TMP=$(mktemp -d /tmp/fm-bound-digest.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
E2E=$TMP/e2e
E2E_ROOT=$E2E/root
E2E_HOME=$E2E/home
E2E_FAKEBIN=$E2E/fakebin
mkdir -p "$E2E_HOME/state" "$E2E_HOME/data" "$E2E_HOME/config" "$E2E_FAKEBIN"
git init -q -b main "$E2E_ROOT"
git -C "$E2E_ROOT" commit -q --allow-empty -m init

cat > "$E2E_FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf '%s\n' '0.2.5'; exit 0 ;;
  update)
    [ "${2:-}" = --help ] || exit 0
    printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --body-file <path>' '  --archive-body'
    exit 0 ;;
  mv)
    [ "${2:-}" = --help ] || exit 0
    printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
    exit 0 ;;
  show)
    [ -z "${2:-}" ] && { printf 'code: NOT_FOUND\n' >&2; exit 1; }
    sleep 300
    exit 0 ;;
  hold)
    [ "${2:-}" = --help ] || exit 0
    printf '%s\n' 'usage: tasks-axi hold <id> [flags]' '  --kind captain' '  --until <date>'
    exit 0 ;;
  add) exit 0 ;;
  list)
    printf 'count: 0\n'
    printf 'tasks[0]{id,state,kind,repo,title,blocked_by,hold_kind,hold_reason}:\n'
    exit 0 ;;
esac
exit 0
SH
chmod +x "$E2E_FAKEBIN/tasks-axi"

for tool in tmux node chrome-devtools-axi gh treehouse; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$E2E_FAKEBIN/$tool"
  chmod +x "$E2E_FAKEBIN/$tool"
done
for tool in lavish-axi gh-axi; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" 0.1.46\n' > "$E2E_FAKEBIN/$tool"
  chmod +x "$E2E_FAKEBIN/$tool"
done

printf '# Backlog\n' > "$E2E_HOME/data/backlog.md"
{
  printf 'window=firstmate:fm-wedged-task\n'
  printf 'worktree=/nonexistent/wedged-task\n'
  printf 'project=alpha\n'
  printf 'harness=claude\n'
  printf 'mode=no-mistakes\n'
  printf 'yolo=off\n'
} > "$E2E_HOME/state/wedged-task.meta"

START=$(date +%s)
env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
  FM_HOME="$E2E_HOME" FM_ROOT_OVERRIDE="$E2E_ROOT" PATH="$E2E_FAKEBIN:$BASE_PATH" \
  FM_BACKLOG_ROW_TIMEOUT_SECS="$BOUND_SECS" \
  "$ROOT/bin/fm-session-start.sh" > "$EV/wedged-backend-session-start-digest.txt" 2>&1 || true
ELAPSED=$(( $(date +%s) - START ))
printf '\n[fm-session-start.sh completed in %ss against the wedged backend]\n' "$ELAPSED" \
  >> "$EV/wedged-backend-session-start-digest.txt"
echo "digest written: $EV/wedged-backend-session-start-digest.txt (${ELAPSED}s)"
