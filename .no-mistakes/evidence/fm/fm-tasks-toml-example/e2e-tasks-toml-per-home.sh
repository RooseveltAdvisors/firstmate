#!/usr/bin/env bash
# End-to-end evidence for the .tasks.toml per-home untracking change.
# Exercises the REAL bin/fm-update.sh and bin/fm-bootstrap.sh from the worktree
# against fixture homes, and prints a transcript of the user-visible behavior.
set -u
WT=/home/jon/.no-mistakes/worktrees/16b9fb59e3d9/01M2M7EQNPVTQ0STNP41W2782J
OUT=/home/jon/.no-mistakes/evidence/01M2M7EQNPVTQ0STNP41W2782J/e2e-transcript.txt
WORK=$(mktemp -d /tmp/fm-e2e-tasks-toml.XXXXXX)
: > "$OUT"

log() { printf '%s\n' "$*" >> "$OUT"; }
run() { printf '$ %s\n' "$*" >> "$OUT"; "$@" >> "$OUT" 2>&1; }

export FM_E2E_WORK="$WORK"
fm_git_identity() { export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.com \
  GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.com; }

. "$WT/tests/lib.sh" >/dev/null 2>&1 || true

log "=============================================================="
log "E2E: .tasks.toml becomes per-home local material"
log "Worktree under test: $WT"
log "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "=============================================================="

fm_git_identity
UPDATE="$WT/bin/fm-update.sh"

# ---------------------------------------------------------------- world build
w="$WORK/world"
mkdir -p "$w/home/state" "$w/home/data" "$w/fakebin" "$w/fake"
: > "$w/fake/windows"
cat > "$w/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) cat "$FM_FAKE_DIR/windows" ;;
  display-message)
    target=
    for arg in "$@"; do case "$arg" in main:fm-*) target=$arg ;; esac; done
    case "${*: -1}" in
      *pane_current_command*)
        id=${target##*fm-}
        if [ -e "$FM_FAKE_DIR/dead-$id" ]; then printf 'zsh\n'; else printf 'claude\n'; fi ;;
      *) printf '\n' ;;
    esac ;;
esac
SH
chmod +x "$w/fakebin/tmux"
touch "$w/home/state/.last-watcher-beat"
git init -q --bare "$w/origin.git"
git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$w/origin.git" "$w/seed"
printf 'v1\n' > "$w/seed/AGENTS.md"
printf 'r1\n' > "$w/seed/README.md"
mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
printf 'echo a\n' > "$w/seed/bin/tool.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$w/seed/bin/fm-remote-secondmate-control.sh"
chmod +x "$w/seed/bin/fm-remote-secondmate-control.sh"
printf 's1\n' > "$w/seed/.agents/skills/note.md"
git -C "$w/seed" add -A; git -C "$w/seed" commit -qm c1
git -C "$w/seed" push -q origin main
git clone -q "$w/origin.git" "$w/main"
git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

# secondmate home (detached worktree of the firstmate repo, like a treehouse lease)
git -C "$w/main" worktree add -q --detach "$w/a1" main
{
  printf 'window=main:fm-a1\n'
  printf 'endpoint_task_id=a1\n'
  printf 'worktree=%s/a1\n' "$w"
  printf 'project=%s/a1\n' "$w"
  printf 'kind=secondmate\n'
  printf 'harness=claude\n'
  printf 'home=%s/a1\n' "$w"
} > "$w/home/state/a1.meta"
printf 'fm-a1\n' >> "$w/fake/windows"
printf '%s\n' a1 > "$w/a1/.fm-secondmate-home"

# Seed a CUSTOMIZED tracked .tasks.toml in both homes: a custom backlog path.
seed_tracked_tasks_config() {  # <home>
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/my-own-backlog.md"\ndone_keep = 3\n' > "$1/.tasks.toml"
  git -C "$1" add .tasks.toml
  git -C "$1" commit -qm home-customized-tasks-toml
  git -C "$1" push -q origin HEAD:main 2>/dev/null || git -C "$1" push -q origin main
}
seed_tracked_tasks_config "$w/main"
git -C "$w/origin.git" fetch -q origin main:main 2>/dev/null
git -C "$w/a1" fetch -q origin
git -C "$w/a1" checkout -q FETCH_HEAD
printf 'backend = "markdown"\n\n[markdown]\npath = "data/mate-backlog.md"\ndone_keep = 3\n' > "$w/a1/.tasks.toml"
git -C "$w/a1" commit -aqm mate-customized-tasks-toml

log ""
log "--- BEFORE the advance -----------------------------------------------"
log "primary home .tasks.toml:      $(cat "$w/main/.tasks.toml" | tr '\n' ' ')"
log "secondmate home .tasks.toml:   $(cat "$w/a1/.tasks.toml" | tr '\n' ' ')"
log "git tracks .tasks.toml:        $(git -C "$w/main" ls-files .tasks.toml)"

# Publish the untracking commit to origin (what this PR ships upstream).
git -C "$w/seed" pull -q origin main
git -C "$w/seed" mv .tasks.toml .tasks.toml.example
printf '.tasks.toml\n' >> "$w/seed/.gitignore"
printf 'v2\n' > "$w/seed/README.md"
git -C "$w/seed" add -A
git -C "$w/seed" commit -qm untrack-tasks-toml
git -C "$w/seed" push -q origin main

log ""
log "--- Run the REAL update: bin/fm-update.sh ----------------------------"
log "(this fast-forwards both homes across the commit that renames"
log " .tasks.toml -> .tasks.toml.example and gitignores the live file)"
log ""
run env PATH="$w/fakebin:$PATH" FM_FAKE_DIR="$w/fake" \
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/main" \
  bash "$UPDATE"

log ""
log "--- AFTER the advance ------------------------------------------------"
log "primary home .tasks.toml:      $(cat "$w/main/.tasks.toml" | tr '\n' ' ')"
log "secondmate home .tasks.toml:   $(cat "$w/a1/.tasks.toml" | tr '\n' ' ')"
log "gitignore now ignores it:      $(git -C "$w/main" check-ignore -v .tasks.toml)"
log "customization intact:          $(grep -q 'data/my-own-backlog.md' "$w/main/.tasks.toml" && echo YES || echo NO)"
log "mate customization intact:     $(grep -q 'data/mate-backlog.md' "$w/a1/.tasks.toml" && echo YES || echo NO)"

# ------------------------------------------------------- bootstrap materialization
log ""
log "--- Run the REAL bootstrap on a FRESH home (no .tasks.toml) ----------"
root="$w/fresh-root"; home="$w/fresh-home"
mkdir -p "$home/config" "$home/state" "$home/data"
printf '%s\n' codex > "$home/config/crew-harness"
printf '%s\n' '{"rules":[{"when":"normal work","use":{"harness":"codex"}}],"default":{"harness":"claude","effort":"low"}}' \
  > "$home/config/crew-dispatch.json"
cp -r "$WT" "$root" 2>/dev/null
rm -rf "$root/.git" "$root/.gitignore"  # materialization runs on the copied tree
printf '%s\n' '.tasks.toml' >> "$root/.gitignore"
printf '%s\n' 'instructions' > "$root/AGENTS.md"
git init -q -b main "$root"
git -C "$root" add -A >/dev/null 2>&1; git -C "$root" commit -qm initial >/dev/null 2>&1

# minimal fake toolchain sufficient for the routine bootstrap path
fakebin="$w/freshbin"; mkdir -p "$fakebin"
fm_fakebin_dir="$fakebin"
for c in tmux node chrome-devtools-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$c"; done
printf '#!/usr/bin/env bash\n[ "$1" = --version ] && { printf "lavish-axi 0.1.46\\n"; exit 0; }\nexit 0\n' > "$fakebin/lavish-axi"
printf '#!/usr/bin/env bash\n[ "$1" = --version ] && { printf "0.1.29\\n"; exit 0; }\nexit 0\n' > "$fakebin/gh-axi"
printf '#!/usr/bin/env bash\n[ "$1" = --version ] && { printf "0.1.29\\n"; exit 0; }\nexit 0\n' > "$fakebin/quota-axi"
printf '#!/usr/bin/env bash\nif [ "$1 $2" = "get --help" ]; then printf "Usage: treehouse get\\n"; fi\nexit 0\n' > "$fakebin/treehouse"
printf '#!/usr/bin/env bash\n[ "$1" = --version ] && { printf "no-mistakes version v1.46.0 (fake)\\n"; exit 0; }\nexit 0\n' > "$fakebin/no-mistakes"
printf '#!/usr/bin/env bash\n[ "$1" = --version ] && { printf "0.2.4\\n"; exit 0; }\nexit 0\n' > "$fakebin/tasks-axi"
chmod +x "$fakebin"/*

log ""
run env PATH="$fakebin:$PATH" FM_BACKEND=tmux FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
  FM_FAKE_TREEHOUSE_LEASE_HELP=1 bash "$root/bin/fm-bootstrap.sh"
log ""
log "fresh home .tasks.toml now exists:  $( [ -f "$home/.tasks.toml" ] && echo YES || echo NO )"
log "matches the tracked example:        $( cmp -s "$home/.tasks.toml" "$WT/.tasks.toml.example" && echo YES || echo NO )"
log "content: $(tr '\n' ' ' < "$home/.tasks.toml")"

log ""
log "--- Run the REAL bootstrap on a home with its OWN customized copy ----"
home2="$w/fresh-home-2"
mkdir -p "$home2/config" "$home2/state" "$home2/data"
printf '%s\n' codex > "$home2/config/crew-harness"
printf '%s\n' '{"rules":[{"when":"normal work","use":{"harness":"codex"}}],"default":{"harness":"claude","effort":"low"}}' \
  > "$home2/config/crew-dispatch.json"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/precious-custom-backlog.md"\ndone_keep = 99\n' > "$home2/.tasks.toml"
run env PATH="$fakebin:$PATH" FM_BACKEND=tmux FM_HOME="$home2" FM_ROOT_OVERRIDE="$root" \
  FM_FAKE_TREEHOUSE_LEASE_HELP=1 bash "$root/bin/fm-bootstrap.sh"
log ""
log "customized copy untouched:          $( grep -q 'precious-custom-backlog.md' "$home2/.tasks.toml" && grep -q 'done_keep = 99' "$home2/.tasks.toml" && echo YES || echo NO )"

log ""
log "E2E COMPLETE"
rm -rf "$WORK"
echo "transcript written to $OUT"
