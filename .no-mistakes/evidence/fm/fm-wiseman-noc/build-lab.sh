#!/usr/bin/env bash
# Build the disposable lab home and private tmux fixture used by the fm-wiseman-noc
# live validation scenarios. Run from the run worktree. Removes nothing; teardown
# is in teardown-lab.sh.
set -eu

WT=${WT:-/home/jon/.no-mistakes/worktrees/46339c0817e0/01M3G30814BNJEZTBE1P25ZC4J}
EV=${EV:-/home/jon/.no-mistakes/evidence/01M3G30814BNJEZTBE1P25ZC4J}
cd "$WT"

LAB=$(cat "$EV/LAB.path" 2>/dev/null || true)
if [ -z "$LAB" ] || [ ! -d "$LAB" ]; then
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  bin/fm-lab-home.sh create "$LAB" >/dev/null
  printf '%s\n' "$LAB" > "$EV/LAB.path"
fi
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
NOW=$(date +%s)
printf '%s\n' "$NOW" > "$EV/FIXTURE_NOW"

# --- private tmux server with lane panes ------------------------------------
tmux kill-server 2>/dev/null || true
sleep 0.3
# A pane whose foreground process is a binary named `pi` classifies alive, and
# its scrollback carries whatever text the scenario needs.
mkdir -p "$LAB/bin"
cp /bin/sleep "$LAB/bin/pi"
cat > "$LAB/pane-clean.sh" <<EOF
#!/usr/bin/env bash
echo "pi: session ready, nothing to report"
exec "$LAB/bin/pi" 7200
EOF
cat > "$LAB/pane-budget.sh" <<EOF
#!/usr/bin/env bash
for i in 1 2 3 4; do echo "429 Account budget exceeded"; done
exec "$LAB/bin/pi" 7200
EOF
chmod +x "$LAB/pane-clean.sh" "$LAB/pane-budget.sh"
tmux new-session -d -s lab -n healthy "$LAB/pane-clean.sh"
for w in stalled beatstale neveranswers claims; do
  tmux new-window -d -t lab -n "$w" "$LAB/pane-clean.sh"
done
tmux new-window -d -t lab -n providerdead "$LAB/pane-budget.sh"
tmux new-window -d -t lab -n movesundererror "$LAB/pane-budget.sh"
sleep 1.5

# --- lane fixture helpers ----------------------------------------------------
lane_home() { mkdir -p "$LAB/lanes/$1/state"; : > "$LAB/lanes/$1/state/.last-watcher-beat"; }
write_meta() {  # <lane> <extra lines...>
  local lane=$1; shift
  {
    printf 'window=lab:%s\n' "$lane"
    printf 'endpoint_task_id=%s\n' "$lane"
    printf 'worktree=%s\n' "$LAB/lanes/$lane"
    printf 'project=%s\n' "$LAB/lanes/$lane"
    printf 'harness=pi\n'
    printf 'kind=secondmate\n'
    printf 'mode=secondmate\n'
    printf 'yolo=off\n'
    printf 'home=%s\n' "$LAB/lanes/$lane"
    printf 'projects=alpha\n'
    local kv
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "$LAB/state/$lane.meta"
}
touch_epoch() { touch -d "@$1" "$2"; }

for l in healthy stalled providerdead beatstale neveranswers movesundererror noinbox frozen gonewindow claims; do
  lane_home "$l"
done

write_meta healthy
write_meta stalled
write_meta providerdead
write_meta beatstale
write_meta neveranswers
write_meta movesundererror
lane_home noinbox
write_meta noinbox
write_meta frozen          # then drop window=: pane and agent both unread
sed -i '/^window=/d' "$LAB/state/frozen.meta"
write_meta gonewindow      # window=lab:ghost does not exist: endpoint missing
write_meta claims

# THE-FM refusal fixture: a lane record whose home IS this home.
mkdir -p "$LAB/state" 
{
  printf 'harness=pi\nkind=secondmate\nmode=secondmate\n'
  printf 'home=%s\n' "$LAB"
  printf 'projects=alpha\n'
} > "$LAB/state/itself.meta"
# A record that is not a response lane at all.
{
  printf 'kind=firstmate\nhome=%s\nprojects=alpha\n' "$LAB/lanes/bystander"
} > "$LAB/state/bystander.meta"

# --- inboxes -----------------------------------------------------------------
S="$LAB/state"
mkdir -p "$S/healthy.inbox/handled" "$S/stalled.inbox/handled" \
         "$S/providerdead.inbox/handled" "$S/beatstale.inbox" \
         "$S/neveranswers.inbox" "$S/movesundererror.inbox/handled" \
         "$S/frozen.inbox/handled" "$S/gonewindow.inbox" "$S/claims.inbox"
printf 'corr=aaaa0001\n' > "$S/healthy.inbox/handled/001.msg"
printf 'x\n' > "$S/stalled.inbox/001.msg"; touch_epoch $(( NOW - 1860 )) "$S/stalled.inbox/001.msg"
printf 'x\n' > "$S/stalled.inbox/handled/001.msg"
printf 'x\n' > "$S/providerdead.inbox/handled/001.msg"
printf 'x\n' > "$S/movesundererror.inbox/handled/001.msg"
for i in 1 2 3 4 5 6 7; do printf 'x\n' > "$S/frozen.inbox/handled/$i.msg"; done
printf 'x\n' > "$S/frozen.inbox/001.msg"; touch_epoch $(( NOW - 1860 )) "$S/frozen.inbox/001.msg"
printf 'x\n' > "$S/gonewindow.inbox/001.msg"; touch_epoch $(( NOW - 1860 )) "$S/gonewindow.inbox/001.msg"

# neveranswers: 5 tracked requests unanswered, 1 resolved -> 83% missed.
for i in 1 2 3 4 5; do printf 'pending-reply-missed: pending-reply-id=miss%s\n' "$i" >> "$S/neveranswers.status"; done
printf 'pending-reply-resolved: pending-reply-id=done1\n' >> "$S/neveranswers.status"

# beatstale: supervision in its home stopped 4000s ago.
touch_epoch $(( NOW - 4000 )) "$LAB/lanes/beatstale/state/.last-watcher-beat"

# --- remote lane over real ssh to localhost ----------------------------------
R="$LAB/remotehome/state"
mkdir -p "$R/parent-route/svcops.inbox/handled"
printf 'corr=bbbb0001\n' > "$R/parent-route/svcops.inbox/001.msg"; touch_epoch $(( NOW - 2000 )) "$R/parent-route/svcops.inbox/001.msg"
printf 'corr=bbbb0002\n' > "$R/parent-route/svcops.inbox/002.msg"; touch_epoch $(( NOW - 1900 )) "$R/parent-route/svcops.inbox/002.msg"
printf 'corr=bbbb0000\n' > "$R/parent-route/svcops.inbox/handled/001.msg"
: > "$LAB/remotehome/state/.last-watcher-beat"
{
  printf 'harness=pi\nkind=secondmate\nmode=secondmate\nremote_host=localhost\n'
  printf 'home=%s\n' "$LAB/remotehome"
  printf 'projects=alpha\n'
} > "$LAB/state/svcops.meta"

# --- the rail's own journal, as an earlier sweep would have left it ----------
cat > "$S/.lane-liveness-lanes" <<EOF
healthy none $(( NOW - 3000 )) 1
stalled none $(( NOW - 2400 )) 1
providerdead budget_exceeded $(( NOW - 700 )) 0
beatstale none $(( NOW - 3000 )) 0
neveranswers none $(( NOW - 3000 )) 0
movesundererror budget_exceeded $(( NOW - 30 )) 0
frozen none $(( NOW - 2400 )) 5
gonewindow none $(( NOW - 3000 )) 0
claims none $(( NOW - 3000 )) 0
EOF

# --- config ------------------------------------------------------------------
cat > "$LAB/config/response-lanes.conf" <<'EOF'
# lab fixture: thresholds stated with their defaults
W=900
D=1800
E=600
M=50
SELF=900
SSH_TIMEOUT=10
CAPTURE_TIMEOUT=8
# ladder keys (owned by bin/fm-lane-recover.sh, skipped by the rail)
RECOVERY=off
SWITCH_MODEL=glm-5.3-flash
lane healthy
lane stalled
lane providerdead
lane beatstale
lane neveranswers
lane movesundererror
lane noinbox
lane frozen
lane gonewindow
lane claims
lane itself
lane bystander
lane svcops
EOF

# --- alert-route seat registry ----------------------------------------------
mkdir -p "$LAB/data"
cat > "$LAB/data/secondmates.md" <<'EOF'
- gpu-ops - GPU host guardian (home: /nope; scope: all rails under the gpu.* namespace; projects: alpha; added 2026-01-01)
- monitor-sre - Monitor guardian (home: /nope; scope: rails prefixed monitor. and the monitor service itself; projects: alpha; added 2026-01-01)
- storage-ops - Storage guardian (home: /nope; scope: capacity, quota, and volume health; projects: alpha; added 2026-01-01)
EOF

printf 'lab=%s\n' "$LAB"
tmux list-windows -t lab -F '#{window_name} #{pane_current_command}'
