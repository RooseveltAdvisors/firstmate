#!/usr/bin/env bash
# tests/fm-spawn-bootstrap.test.sh - the spawn URL/shorthand bootstrap and its
# wrong-checkout guard (bin/fm-spawn.sh bootstrap_project_arg).
#
# Every case drives the real fm-spawn.sh end-to-end against an isolated home:
# a repo URL or owner/name shorthand for a not-yet-cloned project must clone it
# into projects/ and the spawn must adopt that clone; an existing projects/
# checkout is reused only when it is a git work-tree root whose origin matches
# the requested repo. A same-basename fork, a stale plain directory inside an
# enclosing repo, or any other mismatch must be refused - never silently
# adopted.
#
# The fake treehouse leases a REAL isolated worktree of the project the pane is
# sitting in, exactly what the real tool does for `treehouse get`, so the
# worktree= and project= records the spawn writes are proven to come from the
# checkout the bootstrap selected. The assertions read product outputs and
# git's own origin/worktree records - never bin/fm-spawn.sh's source.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-bootstrap)

assert_not_contains() { # <haystack> <needle> <msg>
  case "$1" in
  *"$2"*) fail "$3" ;;
  esac
}

# make_case <name> -> echoes "<home>|<fakebin>|<pane>"
# A spawn home with a brief for T1 and a fakebin whose tmux emulates the pane
# shell executing a typed `treehouse get` (the fake treehouse leases a real
# worktree of $FM_TEST_TREEHOUSE_PROJECT into $FM_FAKE_PANE_PATH).
make_case() {
  local name=$1 case_dir home fakebin pane
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  pane="$case_dir/pane"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get)
    wt="${FM_FAKE_PANE_PATH:?}"
    mkdir -p "$(dirname "$wt")"
    git worktree add --quiet -b fm/test-wt "$wt" || true
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/treehouse"
  mv "$fakebin/tmux" "$fakebin/.tmux-stub"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
for a in "$@"; do
  if [ "$a" = "treehouse get" ] && [ -n "${FM_TEST_TREEHOUSE_PROJECT:-}" ]; then
    (cd "$FM_TEST_TREEHOUSE_PROJECT" && treehouse get) || true
  fi
done
exec "$(dirname "$0")/.tmux-stub" "$@"
SH
  chmod +x "$fakebin/tmux"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" T1
  printf '%s\n' "$home|$fakebin|$pane"
}

read_case() {
  IFS='|' read -r HOME_DIR FAKEBIN_DIR PANE_DIR <<EOF
$1
EOF
}

# run_case <treehouse-project-dir> <project-arg> [gitconfig]: run the T1 ship
# spawn and capture its combined output. The optional gitconfig pins git's
# config for the run (the suite default is /dev/null).
run_case() {
  local treehouse_proj=$1 proj_arg=$2 gcfg=${3:-/dev/null} status
  export GIT_CONFIG_GLOBAL="$gcfg"
  FM_TEST_TREEHOUSE_PROJECT="$treehouse_proj" \
    FM_FAKE_LAUNCH_LOG="$HOME_DIR/launch.log" \
    FM_FAKE_PANE_LOG="$HOME_DIR/pane.log" \
    fm_test_run_spawn "$HOME_DIR" "$PANE_DIR" "$FAKEBIN_DIR" \
    T1 "$proj_arg" --mode no-mistakes --yolo off
  status=$?
  export GIT_CONFIG_GLOBAL=/dev/null
  return "$status"
}

# mirror_gitconfig <name> <local-prefix>: a gitconfig whose insteadOf maps
# https://github.com/ onto a local mirror directory, so the github URL and
# owner/name forms clone from a hermetic fixture while git still records the
# requested URL as the origin.
mirror_gitconfig() {
  local name=$1 prefix=$2 cfg
  cfg="$TMP_ROOT/$name.gitconfig"
  printf '[url "%s/"]\n\tinsteadOf = https://github.com/\n' "$prefix" > "$cfg"
  printf '%s\n' "$cfg"
}

# seed_checkout <dir> <mirror-repo> <stored-origin> <marker>: a git checkout
# cloned from a local mirror whose RECORDED origin is the github URL (fetchable
# through the insteadOf mirror, compared literally by the reuse gate), plus a
# marker file proving later reuse.
seed_checkout() {
  local dir=$1 mirror=$2 origin=$3 marker=$4
  git clone --quiet "$mirror" "$dir"
  git -C "$dir" remote set-url origin "$origin"
  printf 'fixture\n' > "$dir/$marker"
  git -C "$dir" add "$marker"
  git -C "$dir" -c user.email=fm-test@example.invalid -c user.name=fm-test \
    commit -q -m "seed $marker"
}

# seed_mirror <name>: an empty seeded repo in this case's mirror directory,
# returned so a seeded checkout and its fetches share one history.
seed_mirror() {
  local mirror="$TMP_ROOT/mirror-$1/acme"
  mkdir -p "$mirror"
  git init -q -b main "$mirror/tools.git"
  git -C "$mirror/tools.git" -c user.email=fm-test@example.invalid \
    -c user.name=fm-test commit -q --allow-empty -m seed
  printf '%s\n' "$mirror/tools.git"
}

# A URL for a not-yet-cloned project is cloned into projects/<basename> and the
# spawn adopts that clone: the recorded project= is the clone, and the worktree
# it launches into is a worktree OF THAT CLONE (git's own worktree records).
test_url_clone_bootstraps_and_adopts() {
  local rec out status origin common wt_common
  rec=$(make_case url-clone)
  read_case "$rec"
  mkdir -p "$TMP_ROOT/mirror-url/acme"
  git init -q "$TMP_ROOT/mirror-url/acme/tools"
  git -C "$TMP_ROOT/mirror-url/acme/tools" \
    -c user.email=fm-test@example.invalid -c user.name=fm-test \
    commit -q --allow-empty -m seed
  out=$(run_case "$HOME_DIR/projects/tools" https://github.com/acme/tools \
    "$(mirror_gitconfig url-clone "$TMP_ROOT/mirror-url")")
  status=$?
  expect_code 0 "$status" "URL bootstrap spawn should succeed: $out"
  assert_contains "$out" \
    "fm-spawn: bootstrapping project tools from https://github.com/acme/tools into $HOME_DIR/projects/tools" \
    "the spawn reports the clone it performs"
  origin=$(git -C "$HOME_DIR/projects/tools" config --get remote.origin.url)
  assert_equals "https://github.com/acme/tools" "$origin" \
    "the clone records the requested URL as its origin"
  assert_contains "$out" "spawned T1" "the spawn completes and launches the worker"
  assert_contains "$(cat "$HOME_DIR/state/T1.meta")" "project=$HOME_DIR/projects/tools" \
    "task metadata adopts the bootstrapped clone as the project root"
  wt_common=$(grep '^worktree=' "$HOME_DIR/state/T1.meta")
  wt_common=${wt_common#worktree=}
  common=$(git -C "$HOME_DIR/projects/tools" rev-parse --path-format=absolute --git-common-dir)
  [ -n "$wt_common" ] || fail "the spawn recorded no worktree"
  [ "$(git -C "$wt_common" rev-parse --path-format=absolute --git-common-dir)" = "$common" ] \
    || fail "the launched worktree is not a worktree of the bootstrapped clone"
  pass "a repo URL for a not-yet-cloned project is cloned into projects/ and adopted"
}

# The owner/name shorthand is the same bootstrap with a github URL: it clones
# and adopts without the operator ever spelling a URL.
test_shorthand_clone_bootstraps() {
  local rec out status origin
  rec=$(make_case shorthand-clone)
  read_case "$rec"
  mkdir -p "$TMP_ROOT/mirror-sh/acme"
  git init -q "$TMP_ROOT/mirror-sh/acme/tools"
  git -C "$TMP_ROOT/mirror-sh/acme/tools" \
    -c user.email=fm-test@example.invalid -c user.name=fm-test \
    commit -q --allow-empty -m seed
  out=$(run_case "$HOME_DIR/projects/tools" acme/tools \
    "$(mirror_gitconfig shorthand-clone "$TMP_ROOT/mirror-sh")")
  status=$?
  expect_code 0 "$status" "shorthand bootstrap spawn should succeed: $out"
  assert_contains "$out" \
    "fm-spawn: bootstrapping project tools from https://github.com/acme/tools into $HOME_DIR/projects/tools" \
    "the shorthand expands to the github URL and clones it"
  origin=$(git -C "$HOME_DIR/projects/tools" config --get remote.origin.url)
  assert_equals "https://github.com/acme/tools" "$origin" \
    "the shorthand clone records the expanded URL as its origin"
  assert_contains "$out" "spawned T1" "the spawn completes and launches the worker"
  pass "an owner/name shorthand clones its github repo into projects/ and adopts it"
}

# A genuine match (origin equals the requested repo modulo a .git suffix) keeps
# the reuse: no re-clone, the existing checkout is the project.
test_matching_checkout_reused() {
  local rec out status mirror
  rec=$(make_case reuse-match)
  read_case "$rec"
  mirror=$(seed_mirror reuse-match)
  seed_checkout "$HOME_DIR/projects/tools" "$mirror" "https://github.com/acme/tools.git" marker.txt
  out=$(run_case "$HOME_DIR/projects/tools" https://github.com/acme/tools \
    "$(mirror_gitconfig reuse-match "$TMP_ROOT/mirror-reuse-match")")
  status=$?
  expect_code 0 "$status" "a matching checkout should be reused and spawn: $out"
  assert_not_contains "$out" "fm-spawn: bootstrapping project" \
    "a matching checkout must not be re-cloned"
  [ -f "$HOME_DIR/projects/tools/marker.txt" ] \
    || fail "the reused checkout was replaced instead of reused"
  assert_contains "$out" "spawned T1" "the spawn completes and launches the worker"
  assert_contains "$(cat "$HOME_DIR/state/T1.meta")" "project=$HOME_DIR/projects/tools" \
    "task metadata adopts the matching existing checkout"
  pass "an existing checkout whose origin matches the requested repo is reused, not re-cloned"
}

# Adversarial: same-basename fork. projects/tools holds acme/tools; the spawn
# asks for othercorp/tools. It must refuse - never silently adopt the wrong
# codebase - and launch nothing.
test_fork_mismatch_refuses() {
  local rec out status mirror
  rec=$(make_case fork-mismatch)
  read_case "$rec"
  mirror=$(seed_mirror fork-mismatch)
  seed_checkout "$HOME_DIR/projects/tools" "$mirror" "https://github.com/acme/tools.git" marker.txt
  out=$(run_case "$HOME_DIR/projects/tools" https://github.com/othercorp/tools)
  status=$?
  [ "$status" -ne 0 ] || fail "a same-basename fork must refuse, got exit 0: $out"
  assert_contains "$out" "refusing to reuse $HOME_DIR/projects/tools" \
    "the refusal names the checkout it will not adopt"
  assert_contains "$out" "does not match https://github.com/othercorp/tools" \
    "the refusal names the origin mismatch"
  [ -f "$HOME_DIR/projects/tools/marker.txt" ] \
    || fail "the refused checkout must be left untouched"
  [ ! -f "$HOME_DIR/state/T1.meta" ] \
    || fail "a refused spawn must record no task metadata"
  [ ! -s "$HOME_DIR/launch.log" ] \
    || fail "a refused spawn must launch no worker"
  pass "a same-basename fork is refused instead of silently adopting the wrong checkout"
}

# Adversarial (the git walk-up class): projects/firstmate is a stale PLAIN
# directory inside an enclosing checkout whose origin equals the requested
# URL. git config discovery would walk up and "prove" that origin; the reuse
# gate must refuse because the named directory is not a git work-tree root.
test_stale_plain_dir_refuses() {
  local rec out status
  rec=$(make_case stale-plain-dir)
  read_case "$rec"
  # The home itself is the enclosing git checkout (the intended layout: the
  # firstmate home checkout owns projects/).
  git -C "$HOME_DIR" init -q -b main
  git -C "$HOME_DIR" -c user.email=fm-test@example.invalid -c user.name=fm-test \
    commit -q --allow-empty -m home
  git -C "$HOME_DIR" remote add origin https://github.com/acme/firstmate.git
  mkdir -p "$HOME_DIR/projects/firstmate"
  printf 'stale\n' > "$HOME_DIR/projects/firstmate/stale.txt"
  out=$(run_case "$HOME_DIR/projects/firstmate" https://github.com/acme/firstmate)
  status=$?
  [ "$status" -ne 0 ] || fail "a stale plain directory must refuse, got exit 0: $out"
  assert_contains "$out" \
    "refusing to reuse $HOME_DIR/projects/firstmate: not a git work tree root" \
    "the refusal names the work-tree-root violation, not the enclosing repo's origin"
  [ -f "$HOME_DIR/projects/firstmate/stale.txt" ] \
    || fail "the refused stale directory must be left untouched"
  [ ! -f "$HOME_DIR/state/T1.meta" ] \
    || fail "a refused spawn must record no task metadata"
  [ ! -s "$HOME_DIR/launch.log" ] \
    || fail "a refused spawn must launch no worker"
  pass "a stale plain directory inside an enclosing repo is refused, not adopted via git's walk-up"
}

# The usage/help surface must document the accepted URL/owner-name form and its
# projects/ clone target (the operator-facing contract for the new positional).
test_usage_documents_url_form() {
  local out
  out=$("$SPAWN" --help 2>&1) || fail "fm-spawn.sh --help should exit 0"
  assert_contains "$out" "<project-dir-or-repo-url>" \
    "help must name the URL/shorthand form of the project positional"
  assert_contains "$out" "a git URL, or an" \
    "help must document the accepted URL form"
  assert_contains "$out" "cloned into projects/" \
    "help must document where a missing checkout is cloned"
  pass "fm-spawn.sh --help documents the project-dir-or-repo-url form and its projects/ clone target"
}

test_url_clone_bootstraps_and_adopts
test_shorthand_clone_bootstraps
test_matching_checkout_reused
test_fork_mismatch_refuses
test_stale_plain_dir_refuses
test_usage_documents_url_form
