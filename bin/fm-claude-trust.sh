#!/usr/bin/env bash
# Pre-register Claude Code's workspace trust for the isolated task worktree a
# ship/scout spawn is about to launch a claude crewmate into, so the worker
# reaches its brief instead of wedging on the trust dialog.
#
# Usage: fm-claude-trust.sh <worktree> <project>
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the primary checkout that worktree belongs to
# Prints one line naming what it registered; refuses loudly on anything else.
#
# WHY THIS EXISTS. Claude Code gates a folder it has never seen behind an
# interactive workspace-trust dialog, and --dangerously-skip-permissions does
# NOT cover it: `claude --help` records that the dialog is skipped only in
# non-interactive mode (-p, or a non-TTY stdout), and a crewmate pane is
# interactive. Every fresh task worktree therefore hits it. The dialog renders
# with the cursor on "No, exit" and firstmate's steering plane carries only
# Enter, Escape and C-c with no arrow navigation, so firstmate cannot answer it
# and must not try - pressing Enter would select exit. The worker wedges before
# it ever reads the brief. Registering the trust before launch is the only
# control that reaches an interactive pane.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY, and it is STRUCTURAL rather than a
# path policy. <worktree> must be a LINKED git worktree - its own git dir,
# sharing <project>'s common dir - whose top level is exactly the resolved
# argument. Git is the ground truth, so the argument is never trusted on its
# own word: a primary checkout (git dir == common dir), a worktree of an
# unrelated repo, a subdirectory of a worktree, a plain directory, and a home
# directory are each refused. Refusal is a non-zero exit, never a warning and
# never a silent skip.
#
# The test is deliberately NOT a treehouse or orca path prefix. Treehouse's
# root is configurable (--root, TREEHOUSE_ROOT, config, and a relative
# in-project pool), so a prefix check would refuse legitimate roots, accept
# whatever a mutable env var names, and add exactly the policy surface this
# registration must not grow. One structural test covers both worktree
# providers because Orca's task worktree is a linked git worktree too.
#
# Only the launching user's own store is written: the projects entry for the
# worktree path in ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json, which must be a
# regular file this uid owns. Every unrelated key and project entry is
# preserved, and the replacement is atomic. That resolution is the same one the
# worker reads, because fm-spawn.sh forwards its own resolved CLAUDE_CONFIG_DIR
# onto the claude launch and an unset value is the single-store default.
set -u

[ "$#" -eq 2 ] || { echo "usage: fm-claude-trust.sh <worktree> <project>" >&2; exit 2; }
WT_ARG=$1
PROJ_ARG=$2

refuse() { echo "error: refusing to pre-register Claude trust: $1" >&2; exit 1; }

real_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# The resolved common dir of a git worktree, or empty. --git-common-dir can be
# relative, so it is resolved from inside the worktree rather than joined here.
common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd "$dir" && real_dir "$common")
}

WT_REAL=$(real_dir "$WT_ARG") || true
[ -n "$WT_REAL" ] || refuse "worktree '$WT_ARG' is not an accessible directory"
PROJ_REAL=$(real_dir "$PROJ_ARG") || true
[ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"

CONFIG_DIR=${CLAUDE_CONFIG_DIR:-${HOME:-}}
[ -n "$CONFIG_DIR" ] || refuse "neither CLAUDE_CONFIG_DIR nor HOME is set, so the store cannot be located"
# fm-spawn forwards a set CLAUDE_CONFIG_DIR onto the launch without requiring it
# to exist, because claude creates its own store directory. Create it here for
# the same reason, and refuse only when it genuinely cannot be written, since a
# store this cannot reach means the worker meets the dialog after all.
CONFIG_DIR_REAL=$(real_dir "$CONFIG_DIR") || true
if [ -z "$CONFIG_DIR_REAL" ]; then
  mkdir -p "$CONFIG_DIR" 2>/dev/null || true
  CONFIG_DIR_REAL=$(real_dir "$CONFIG_DIR") || true
fi
[ -n "$CONFIG_DIR_REAL" ] || refuse "Claude config directory '$CONFIG_DIR' does not exist and could not be created"

# A home or config directory is never a task worktree. Checked explicitly so
# the refusal names the real reason instead of the git verdict behind it.
[ "$WT_REAL" != "$CONFIG_DIR_REAL" ] || refuse "'$WT_REAL' is the Claude config directory, not a task worktree"
if [ -n "${HOME:-}" ]; then
  HOME_REAL=$(real_dir "$HOME") || true
  [ "$WT_REAL" != "${HOME_REAL:-}" ] || refuse "'$WT_REAL' is the home directory, not a task worktree"
fi

WT_TOP=$(git -C "$WT_REAL" rev-parse --show-toplevel 2>/dev/null) || true
[ -n "$WT_TOP" ] || refuse "'$WT_REAL' is not inside a git repository"
WT_TOP_REAL=$(real_dir "$WT_TOP") || true
[ "$WT_TOP_REAL" = "$WT_REAL" ] || refuse "'$WT_REAL' is not a worktree root (its root is '${WT_TOP_REAL:-unresolvable}')"

WT_GIT_DIR=$(git -C "$WT_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has no resolvable git directory"
WT_GIT_DIR=$(real_dir "$WT_GIT_DIR") || true
WT_COMMON=$(common_dir_of "$WT_REAL") || true
[ -n "$WT_COMMON" ] || refuse "'$WT_REAL' has no resolvable git common directory"
[ "$WT_GIT_DIR" != "$WT_COMMON" ] || refuse "'$WT_REAL' is a primary checkout, not an isolated worktree"

PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
[ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
[ "$WT_COMMON" = "$PROJ_COMMON" ] || refuse "'$WT_REAL' is not a worktree of project '$PROJ_REAL'"

STORE="$CONFIG_DIR_REAL/.claude.json"
if [ -e "$STORE" ] || [ -L "$STORE" ]; then
  [ ! -L "$STORE" ] || refuse "'$STORE' is a symlink; refusing to follow it into another user's store"
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "'$STORE' is not writable"
fi

# Read-modify-write, then read back and confirm. Any running claude session
# holds its own copy of this store and can rewrite the whole file at any time,
# so a dropped entry - never a torn file, the replacement is a rename - is the
# one realistic failure, and re-reading catches it. A lost update would only
# resurrect the dialog this registration exists to remove, so it must fail
# loudly rather than report a trust it did not leave behind.
#
# The readback proves the entry landed, not that it survives: a vendor session
# that rewrites the whole store after this returns can still drop it, and no
# lock closes that window because the writer is Claude itself. The worker then
# meets the dialog and stalls, which reaches firstmate as the ordinary stale
# wake rather than as silent success, and a relaunch registers again.
# ponytail: verify-and-retry, not a lock; flock is absent on macOS and cannot
# stop a vendor session's own rewrite anyway. Reach for a lock only if
# concurrent spawns are ever shown to exhaust the retries.
if ! node - "$STORE" "$WT_REAL" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, worktree] = process.argv.slice(2);
const attempt = () => {
  let root = {};
  if (fs.existsSync(store)) {
    const raw = fs.readFileSync(store, "utf8");
    if (raw.trim() !== "") {
      root = JSON.parse(raw);
      if (root === null || typeof root !== "object" || Array.isArray(root)) {
        throw new Error(`${store} is not a JSON object`);
      }
    }
  }
  if (root.projects === undefined) root.projects = {};
  const projects = root.projects;
  if (projects === null || typeof projects !== "object" || Array.isArray(projects)) {
    throw new Error(`${store} has a non-object "projects" value`);
  }
  let entry = projects[worktree];
  if (entry === undefined || entry === null || typeof entry !== "object" || Array.isArray(entry)) {
    entry = {};
  }
  entry.hasTrustDialogAccepted = true;
  projects[worktree] = entry;
  // Unpredictable name plus an exclusive create: the config directory may be
  // writable by another local account, and a predictable path could be
  // pre-created there as a symlink that a plain write would follow into some
  // other file this user owns. "wx" refuses an existing path outright.
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(store), `.claude.json.fm-trust.${unique}`);
  fs.writeFileSync(tmp, `${JSON.stringify(root, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  try {
    fs.renameSync(tmp, store);
  } catch (err) {
    fs.rmSync(tmp, { force: true });
    throw err;
  }
  const back = JSON.parse(fs.readFileSync(store, "utf8"));
  return back.projects?.[worktree]?.hasTrustDialogAccepted === true;
};
try {
  for (let i = 0; i < 3; i += 1) {
    if (attempt()) process.exit(0);
  }
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
console.error(`error: ${store} did not retain trust for ${worktree} after 3 attempts`);
process.exit(1);
NODE
then
  refuse "could not record trust for '$WT_REAL' in '$STORE'"
fi

echo "trusted: $WT_REAL"
