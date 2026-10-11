#!/usr/bin/env bash
set -u
WT_ROOT=$1; E=$2
cd "$WT_ROOT"
. tests/fixtures.sh
TMP_ROOT=$(fm_test_tmproot fm-live-pi-noapprove)
REALPI=$(command -v pi); REALTMUX=$(command -v tmux)
SOCK=fm-lab-pinoapprove-$$
trap '"$REALTMUX" -L $SOCK kill-server >/dev/null 2>&1; chmod -R u+w "$TMP_ROOT"; rm -rf "$TMP_ROOT"' EXIT
for kind in ship scout; do
  c="$TMP_ROOT/$kind"; home=$c/home; proj=$c/project; wt=$c/wt; log=$c/launch.log; id="live-pi-$kind-q1"
  fakebin=$(fm_test_make_spawn_fakebin "$c/fake")
  printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$fakebin/timeout"; chmod +x "$fakebin/timeout"
  ln -sf "$REALPI" "$fakebin/pi"     # real pi 1.1.0 answers fm-spawn's help probe
  fm_test_spawn_home "$home" pi
  fm_git_worktree "$proj" "$wt" "wt-$kind"
  fm_test_spawn_brief "$home" "$id"
  # project-committed .pi extension that would mark if executed
  MARK=$c/marker-ran; mkdir -p "$proj/.pi/extensions"
  printf 'import { writeFileSync } from "node:fs";\nexport default function () { writeFileSync(%s, "ran"); }\n' "'$MARK'" > "$proj/.pi/extensions/marker.ts"
  git -C "$proj" add .pi && git -C "$proj" -c user.name=t -c user.email=t@t commit -qm "project pi ext"
  : > "$log"
  if [ $kind = scout ]; then extra=(--scout); else extra=(--mode no-mistakes --yolo off); fi
  out=$(CLAUDE_CONFIG_DIR= FM_FAKE_LAUNCH_LOG="$log" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --harness pi "${extra[@]}"); rc=$?
  echo "== $kind: fm-spawn rc=$rc"; [ $rc = 0 ] || { echo "$out"; continue; }
  mkdir -p "$wt/.pi/extensions"; cp "$proj/.pi/extensions/marker.ts" "$wt/.pi/extensions/"; echo "== $kind worktree now carries .pi/extensions/marker.ts"
  launch=$(cat "$log"); echo "== $kind launch command rendered by fm-spawn:"; echo "$launch"
  # run the rendered launch for real in an isolated tmux + disposable pi dir
  PIDIR=$c/pi-agent; mkdir -p "$PIDIR"; echo '{}' > "$PIDIR/trust.json"
  "$REALTMUX" -L $SOCK new-session -d -s $kind -x 200 -y 50 -c "$wt" -- env HOME="$c/uhome" PI_CODING_AGENT_DIR="$PIDIR" PI_OFFLINE=1 PATH="$fakebin:$PATH" bash -c "$launch"
  for i in $(seq 1 30); do sleep 0.5; p=$("$REALTMUX" -L $SOCK capture-pane -p -t $kind 2>/dev/null); echo "$p" | grep -qE 'No models available|escape interrupt|Trust project folder' && break; done
  echo "== $kind pane:"; echo "$p" | sed '/^\s*$/d' | head -40
  echo "$p" | grep -q 'Trust project folder' && echo "RESULT $kind: STALLED at trust menu" || echo "RESULT $kind: no trust menu"
  [ -e "$MARK" ] && echo "RESULT $kind: project .pi extension RAN" || echo "RESULT $kind: project .pi extension did not run"
  echo "RESULT $kind: trust.json=$(cat "$PIDIR/trust.json")"
  "$REALTMUX" -L $SOCK kill-session -t $kind >/dev/null 2>&1
  ctl=${launch// --no-approve/}; echo '{}' > "$PIDIR/trust.json"
  "$REALTMUX" -L $SOCK new-session -d -s c$kind -x 200 -y 50 -c "$wt" -- env HOME="$c/uhome" PI_CODING_AGENT_DIR="$PIDIR" PI_OFFLINE=1 PATH="$fakebin:$PATH" bash -c "$ctl"
  for i in $(seq 1 30); do sleep 0.5; p=$("$REALTMUX" -L $SOCK capture-pane -p -t c$kind 2>/dev/null); echo "$p" | grep -qE 'No models available|escape interrupt|Trust project folder' && break; done
  echo "== CONTROL $kind (same launch, --no-approve removed) pane:"; echo "$p" | sed '/^\s*$/d' | head -15
  echo "$p" | grep -q 'Trust project folder' && echo "CONTROL $kind: STALLED at trust menu" || echo "CONTROL $kind: no trust menu"
  "$REALTMUX" -L $SOCK send-keys -t c$kind Escape; "$REALTMUX" -L $SOCK kill-session -t c$kind >/dev/null 2>&1
done
