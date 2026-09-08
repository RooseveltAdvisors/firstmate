#!/usr/bin/env bash
# Manual end-to-end verification for the bounded per-item backlog read:
# every command below drives the real bin/fm-captain-hold.sh CLI against a
# fake tasks-axi whose row reads report the read-bound status (124), and
# compares the target change (this worktree) against the base commit
# b84e0e362face25f3dd8945297a3df1320d7668c to show the mislabels it removes.
#
# Paths exercised (the review-round-1/2 fixes):
#   S1  resolve_migrated_entry prefixed-id scan (beads backend): a bound hit
#       during the migrated-prefix scan must reach verify as a bound, not as
#       "no captain-held task ... resolves to nothing".
#   S2  command_reconcile_requests: a bound hit must fail naming the bound,
#       not print "refused: <id> (absent)".
#   S3  command_answers: a bound hit resolving a key must fail naming the
#       bound, not print "skipped: <key> (no captain-held task with that id)".
set -u

ROOT=/home/jon/.no-mistakes/worktrees/46339c0817e0/01M219PH5PH1ZDA571GPZXBHXM
EV=/home/jon/.no-mistakes/evidence/01M219PH5PH1ZDA571GPZXBHXM
BASE_COMMIT=b84e0e362face25f3dd8945297a3df1320d7668c
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
BOUND_SECS=2

TMP=$(mktemp -d /tmp/fm-bound-verify.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

BASE=$TMP/base
mkdir -p "$BASE"
git -C "$ROOT" archive "$BASE_COMMIT" | tar -x -C "$BASE"

# A tasks-axi whose `show` answers the read-bound status (124) for the ids
# under test and NOT_FOUND (exit 1) for everything else, so a dropped 124
# surfaces as "absent" rather than as a bound - exactly the defect shape the
# change must prevent. Everything require_tasks_axi needs answers promptly.
make_tasks_axi() {  # <fakebin>
  cat > "$1/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf '%s\n' '0.2.5'; exit 0 ;;
  show)
    case "${2:-}" in
      fm-migrated-key|fm-wedged-origin-decision-migrated-key|wedged-req|wedged-key)
        printf 'tasks-axi show %s wedged past its read bound\n' "$2"
        exit 124 ;;
      *)
        printf 'code: NOT_FOUND\n' >&2
        exit 1 ;;
    esac ;;
  update)
    [ "${2:-}" = --help ] || exit 0
    printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --body-file <path>' '  --archive-body'
    exit 0 ;;
  mv)
    [ "${2:-}" = --help ] || exit 0
    printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
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
  chmod +x "$1/tasks-axi"
}

# A beads binary whose graph carries no migrated marker notes, so resolution
# falls through to the prefixed-id scan.
make_bd() {  # <fakebin>
  cat > "$1/bd" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list) printf '[]\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/bd"
}

run_one() {  # <script-root> <label> <out-file>
  local tree=$1 label=$2 out=$3 home=$TMP/$label homeargs
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '# Backlog\n' > "$home/data/backlog.md"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  make_tasks_axi "$home"
  case $label in
    s1-migrated-prefix)
      make_bd "$home"
      printf '[beads]\nprefix = "fm-"\npath = "beads-graph"\n' >> "$home/.tasks.toml"
      {
        printf 'window=firstmate:fm-wedged-origin\n'
        printf 'worktree=/nonexistent/wedged-origin\n'
        printf 'project=alpha\n'
        printf 'harness=claude\n'
        printf 'decisions_reviewed=1\n'
        printf 'decision_keys=migrated-key\n'
      } > "$home/state/wedged-origin.meta"
      PATH="$home:$BASE_PATH" TASKS_AXI_BACKEND=beads FM_HOME="$home" \
        FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
        FM_CONFIG_OVERRIDE="$home/config" FM_BACKLOG_ROW_TIMEOUT_SECS="$BOUND_SECS" \
        "$tree/bin/fm-captain-hold.sh" verify wedged-origin > "$out" 2>&1
      ;;
    s2-reconcile-requests)
      PATH="$home:$BASE_PATH" FM_HOME="$home" \
        FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
        FM_CONFIG_OVERRIDE="$home/config" FM_BACKLOG_ROW_TIMEOUT_SECS="$BOUND_SECS" \
        "$tree/bin/fm-captain-hold.sh" bind wedge-src > /dev/null 2>&1
      printf 'wedged-req\n' | \
      PATH="$home:$BASE_PATH" FM_HOME="$home" \
        FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
        FM_CONFIG_OVERRIDE="$home/config" FM_BACKLOG_ROW_TIMEOUT_SECS="$BOUND_SECS" \
        "$tree/bin/fm-captain-hold.sh" reconcile-requests --source-id wedge-src \
        --source 'captured board result' > "$out" 2>&1
      ;;
    s3-answers)
      printf 'wedged-key\tship it\n' | \
      PATH="$home:$BASE_PATH" FM_HOME="$home" \
        FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
        FM_CONFIG_OVERRIDE="$home/config" FM_BACKLOG_ROW_TIMEOUT_SECS="$BOUND_SECS" \
        "$tree/bin/fm-captain-hold.sh" answers --source 'captured board' > "$out" 2>&1
      ;;
  esac
}

for label in s1-migrated-prefix s2-reconcile-requests s3-answers; do
  base_out=$TMP/$label.base.out
  target_out=$TMP/$label.target.out
  base_rc=0; target_rc=0
  run_one "$BASE" "$label" "$base_out" || base_rc=$?
  run_one "$ROOT" "$label" "$target_out" || target_rc=$?
  {
    printf '=== %s: base commit %s ===\n' "$label" "$BASE_COMMIT"
    printf -- '--- exit status: %s ---\n' "$base_rc"
    cat "$base_out"
    printf '\n=== %s: target (branch fm/fm-bootstrap-bounded-backlog-read-successor) ===\n' "$label"
    printf -- '--- exit status: %s ---\n' "$target_rc"
    cat "$target_out"
  } > "$EV/$label.transcript.txt"
done

echo "transcripts written to $EV"
