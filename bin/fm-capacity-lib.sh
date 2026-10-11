#!/usr/bin/env bash
# shellcheck shell=bash
# fm-capacity-lib.sh - the single owner of the treehouse pool capacity hold.
#
# A full worktree pool used to be a silent 60-second wait followed by a failed
# spawn whose item stayed dispatchable, so a busy pool produced a retry loop
# with no record. This library turns that refusal into a recorded hold:
#
#   bin/fm-spawn.sh detects treehouse's exact "all N worktrees are in use"
#   refusal during the treehouse-get wait and holds the item through
#   fm_capacity_hold; fm_capacity_release_after_return releases the oldest hold
#   recorded for the freed pool, in this home first and otherwise in any other
#   local home that can reach the pool, right after this home returns a slot -
#   bin/fm-teardown.sh after its task-worktree, secondmate-home, and forced
#   child-worktree returns, bin/fm-home-seed.sh after the seed rollback's
#   treehouse return.
#
# Reason contract (owned here, consumed by both call sites and the tests):
#   pool <pool-root> full <N>/<max>
#   pool <pool-root> full <N>          (when the refusal carries no max_trees)
# The pool identity is the canonical treehouse pool root directory, falling
# back to the project root when the pool cannot be resolved. Spawn records
# whichever identity it can resolve; teardown scans for the worktree-derived
# pool root first and, when nothing matched, for the project-root fallback
# identity, so a hold recorded under either identity is released.
#
# Hold kind: "load". tasks-axi has no capacity kind; load is its load-based
# hold, and the reason prefix above is what distinguishes a capacity hold from
# any other load hold, so release never touches a hold it did not record.
#
# tasks-axi also refuses reasons containing parentheses, which is why the
# reason spells "full <N>/<max>" instead of the parenthesized form.
#
# Every mutation runs from the owning home's backlog root with `--file` only
# for the markdown backend, mirroring fm_backlog_row_show's backend awareness
# in bin/fm-backlog-transition-lib.sh so backend-owned state stays discoverable.
# fm_capacity_release_after_return also needs bin/fm-wake-lib.sh and
# bin/fm-secondmate-registry-lib.sh sourced by the caller, for the shared
# project lock and the local home registry its cross-home scan uses.
# Usage: . bin/fm-capacity-lib.sh

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-tasks-axi-lib.sh"

fm_capacity_resolve_dir() {  # <dir>
  local dir=$1
  [ -n "$dir" ] || return 1
  CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P
}

fm_capacity_canonical_or_raw() {  # <path>
  local path=$1 canon
  if [ -d "$path" ]; then
    canon=$(fm_capacity_resolve_dir "$path") || canon=$path
    printf '%s\n' "$canon"
  else
    printf '%s\n' "$path"
  fi
}

# The pool root a worktree belongs to: worktrees live at <pool>/<n>/<repo>, so
# the pool is the worktree path's grandparent directory. Both this and
# fm_capacity_pool_of_project must keep deriving pool identity from real
# worktree paths for recorded holds and later releases to agree.
fm_capacity_pool_of_worktree() {  # <worktree-path>
  local wt=$1 pool
  [ -n "$wt" ] || return 1
  pool=$(dirname "$wt")
  pool=$(dirname "$pool")
  fm_capacity_canonical_or_raw "$pool"
}

# The pool root a project resolves to, taken from treehouse's own pool status
# (any worktree path in it answers the layout); the project root itself when
# treehouse cannot answer, so the identity stays unique per project either way.
fm_capacity_pool_of_project() {  # <project-dir>
  local proj=$1 out first pool
  [ -n "$proj" ] || return 1
  proj=$(fm_capacity_canonical_or_raw "$proj")
  if command -v treehouse >/dev/null 2>&1 \
     && out=$( (cd "$proj" 2>/dev/null && treehouse status --json 2>/dev/null) ) \
     && [ -n "$out" ]; then
    first=$(printf '%s\n' "$out" \
      | jq -r 'if (type == "array") and (length > 0) and (.[0].path != null) then .[0].path else empty end' 2>/dev/null)
    if [ -n "$first" ]; then
      pool=$(dirname "$first")
      pool=$(dirname "$pool")
      if [ -n "$pool" ]; then
        fm_capacity_canonical_or_raw "$pool"
        return 0
      fi
    fi
  fi
  printf '%s\n' "$proj"
}

fm_capacity_reason() {  # <pool> <in-use-count> [max]
  local pool=$1 n=$2 max=${3:-}
  if [ -n "$max" ]; then
    printf 'pool %s full %s/%s\n' "$pool" "$n" "$max"
  else
    printf 'pool %s full %s\n' "$pool" "$n"
  fi
}

# Run one tasks-axi command against the backlog owned by <data-dir>'s home,
# with `--file` only for the markdown backend. Prints tasks-axi's combined
# output; the exit status is tasks-axi's.
fm_capacity_axi() {  # <data-dir> <verb> <id> [flag...]
  local data=$1 verb=$2 id=$3 root
  shift 3
  data=$(fm_capacity_resolve_dir "$data") || return 1
  root=$(dirname "$data")
  if [ "$(fm_tasks_axi_backend "$root")" = markdown ]; then
    (cd "$root" 2>/dev/null && tasks-axi "$verb" "$id" --file "$data/backlog.md" "$@" 2>&1)
  else
    (cd "$root" 2>/dev/null && tasks-axi "$verb" "$id" "$@" 2>&1)
  fi
}

# Hold <id> for capacity: a load-kind hold whose reason carries the pool
# identity. Idempotent per tasks-axi's own hold semantics.
fm_capacity_hold() {  # <data-dir> <id> <reason>
  local data=$1 id=$2 reason=$3
  fm_capacity_axi "$data" hold "$id" --reason "$reason" --kind load >/dev/null
}

# Release the oldest capacity hold recorded for <pool> and print which item
# became ready. Candidate rows are the held rows whose hold kind is load and
# whose reason is exactly this library's reason contract for this pool; the
# oldest is the smallest created date, with same-date ties broken by id so
# the choice is deterministic regardless of backend list order (tasks-axi
# exposes only the day, not the hold time). A row set that matches nothing
# releases nothing and stays silent. Never fatal: a release failure is
# reported on stderr and leaves the hold in place for the next teardown to
# retry.
FM_CAPACITY_RELEASED_ID=
FM_CAPACITY_OLDEST_ID=
FM_CAPACITY_OLDEST_CREATED=
# Find the oldest capacity hold recorded for <pool> in <data-dir>'s backlog,
# by the ordering fm_capacity_release_oldest documents, without changing it.
# Sets FM_CAPACITY_OLDEST_ID and FM_CAPACITY_OLDEST_CREATED, both empty when
# nothing matches. A failed read is reported on stderr and matches nothing.
fm_capacity_oldest_hold() {  # <data-dir> <pool>
  local data=$1 pool=$2 out line prefix reason created id
  local best_id='' best_created=''
  FM_CAPACITY_OLDEST_ID=
  FM_CAPACITY_OLDEST_CREATED=
  data=$(fm_capacity_resolve_dir "$data") || return 0
  command -v tasks-axi >/dev/null 2>&1 || return 0
  out=$(fm_capacity_axi "$data" list --state held --fields created,hold_kind,hold_reason) || {
    printf 'teardown: capacity release could not read held rows in %s: %s\n' "$data" "$(printf '%s\n' "$out" | sed -n '1p')" >&2
    return 0
  }
  while IFS= read -r line; do
    case "$line" in
      '  '*) ;;
      *) continue ;;
    esac
    reason=${line##*,load,}
    [ "$reason" != "$line" ] || continue
    case "$reason" in
      "pool $pool full"|"pool $pool full "*) ;;
      *) continue ;;
    esac
    prefix=${line%,load,*}
    created=${prefix##*,}
    case "$created" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) continue ;;
    esac
    id=${line#'  '}
    id=${id%%,*}
    [ -n "$id" ] || continue
    if [ -z "$best_id" ] || [ "$created" \< "$best_created" ] \
       || { [ "$created" = "$best_created" ] && [ "$id" \< "$best_id" ]; }; then
      best_id=$id
      best_created=$created
    fi
  done <<EOF
$out
EOF
  FM_CAPACITY_OLDEST_ID=$best_id
  FM_CAPACITY_OLDEST_CREATED=$best_created
}

fm_capacity_release_oldest() {  # <data-dir> <pool>
  local data=$1 pool=$2
  FM_CAPACITY_RELEASED_ID=
  data=$(fm_capacity_resolve_dir "$data") || return 0
  fm_capacity_oldest_hold "$data" "$pool"
  [ -n "$FM_CAPACITY_OLDEST_ID" ] || return 0
  fm_capacity_unhold "$data" "$FM_CAPACITY_OLDEST_ID" "$pool"
}

# Lift one capacity hold in <data-dir>'s backlog and report it. Never fatal.
fm_capacity_unhold() {  # <data-dir> <id> <pool> [home-note]
  local data=$1 id=$2 pool=$3 note=${4:-}
  if ! fm_capacity_axi "$data" unhold "$id" >/dev/null; then
    printf 'teardown: capacity release of %s%s failed; the hold stays recorded\n' "$id" "$note" >&2
    return 0
  fi
  # Part of this library's output contract: fm-teardown.sh reads it after a
  # successful release, so ShellCheck's in-file use check is a false positive.
  # shellcheck disable=SC2034
  FM_CAPACITY_RELEASED_ID=$id
  printf 'ready: %s - capacity hold released for pool %s%s\n' "$id" "$pool" "$note"
}

# The other local homes that can reach this machine's pools: the local root
# home (bin/fm-wake-lib.sh's fm_firstmate_root_home) and every home reachable
# from it through local data/secondmates.md routes, excluding <self-home>.
# Remote routes are skipped because their backlog lives on another machine and
# their pools are not this machine's. Prints one resolved home per line.
fm_capacity_sibling_homes() {  # <self-home>
  local self root queue home line seen depth=0
  self=$(fm_capacity_resolve_dir "$1") || self=$1
  root=$(fm_firstmate_root_home "$self" 2>/dev/null) || return 0
  queue=$root
  seen="|$root|"
  while [ -n "$queue" ] && [ "$depth" -le 64 ]; do
    home=${queue%%$'\n'*}
    if [ "$home" = "$queue" ]; then queue=; else queue=${queue#*$'\n'}; fi
    depth=$((depth + 1))
    [ "$home" = "$self" ] || printf '%s\n' "$home"
    [ -f "$home/data/secondmates.md" ] || continue
    while IFS= read -r line; do
      secondmate_registry_parse_line "$line" || continue
      [ "$SECONDMATE_REGISTRY_REMOTE" = 0 ] || continue
      line=$(fm_capacity_resolve_dir "$SECONDMATE_REGISTRY_HOME") || continue
      case "$seen" in *"|$line|"*) continue ;; esac
      seen="$seen$line|"
      queue=${queue:+$queue$'\n'}$line
    done < "$home/data/secondmates.md"
  done
}

# Release the oldest capacity hold any OTHER local home recorded for <pool>,
# one release at most. The caller must hold the shared Treehouse project lock
# (bin/fm-wake-lib.sh's fm_treehouse_project_lock_path), which is what makes a
# write to another home's backlog race-safe: every capacity hold is recorded by
# bin/fm-spawn.sh and every capacity release runs under that one machine-wide
# lock, whichever home performs it, so no hold can be recorded or released for
# this pool between this scan and its unhold. Rows of unrelated work in the
# same backlog are serialized by tasks-axi's own backlog lock, and a refused
# write leaves the hold recorded and reports it. A manual-backend sibling is
# never scanned, matching the same-home rule.
fm_capacity_release_oldest_elsewhere() {  # <self-home> <pool>
  local self=$1 pool=$2 home best_home='' best_id='' best_created=''
  FM_CAPACITY_RELEASED_ID=
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    ! fm_backlog_backend_manual "$home/config" || continue
    [ -d "$home/data" ] || continue
    fm_capacity_oldest_hold "$home/data" "$pool"
    [ -n "$FM_CAPACITY_OLDEST_ID" ] || continue
    if [ -z "$best_id" ] || [ "$FM_CAPACITY_OLDEST_CREATED" \< "$best_created" ] \
       || { [ "$FM_CAPACITY_OLDEST_CREATED" = "$best_created" ] && [ "$FM_CAPACITY_OLDEST_ID" \< "$best_id" ]; }; then
      best_home=$home
      best_id=$FM_CAPACITY_OLDEST_ID
      best_created=$FM_CAPACITY_OLDEST_CREATED
    fi
  done <<EOF
$(fm_capacity_sibling_homes "$self")
EOF
  [ -n "$best_id" ] || return 0
  fm_capacity_unhold "$best_home/data" "$best_id" "$pool" " in home $best_home"
}

# Release the oldest capacity hold for the pool whose slot <worktree> just went
# back to it, scanning the project-root fallback identity <project> when the
# worktree-derived pool scan matches nothing, and print which item became
# ready. <data-dir>, the returning home's own backlog, is scanned first. When it
# holds nothing for the pool, the other local homes are scanned (see
# fm_capacity_release_oldest_elsewhere) under the shared Treehouse project lock
# for <project>: <held-lock> names that lock when the caller already holds it,
# and otherwise this function takes it for the scan and releases it after. A
# busy lock skips the cross-home scan with one stderr line, because its holder
# is a spawn that will consume the freed slot or a return that runs its own
# release. Never fatal and silent when the pool cannot be computed: the release
# is the returning side's best effort, never the caller's decision point. A
# home whose config/backlog-backend selects manual editing is skipped outright:
# spawn records no hold there, so release must not mutate a hand-kept backlog.
fm_capacity_release_after_return() {  # <config-dir> <data-dir> <worktree> <project> [held-lock]
  local config=$1 data=$2 worktree=$3 project=$4 held=${5:-} pool fallback lock took=0
  FM_CAPACITY_RELEASED_ID=
  ! fm_backlog_backend_manual "$config" || return 0
  pool=$(fm_capacity_pool_of_worktree "$worktree" 2>/dev/null || true)
  [ -n "$pool" ] || return 0
  fallback=
  if [ -n "$project" ]; then
    fallback=$(fm_capacity_canonical_or_raw "$project" 2>/dev/null || true)
    [ "$fallback" != "$pool" ] || fallback=
  fi
  fm_capacity_release_oldest "$data" "$pool" || true
  if [ -z "$FM_CAPACITY_RELEASED_ID" ] && [ -n "$fallback" ]; then
    fm_capacity_release_oldest "$data" "$fallback" || true
  fi
  [ -z "$FM_CAPACITY_RELEASED_ID" ] || return 0
  # Only a genuine Treehouse slot has the shared project lock behind it, the
  # same rule spawn and teardown use before taking that lock.
  [ -n "$project" ] && fm_treehouse_pool_slot "$project" "$worktree" || return 0
  lock=$(fm_treehouse_project_lock_path "$project" 2>/dev/null) || return 0
  if [ "$lock" != "$held" ]; then
    if ! fm_lock_try_acquire "$lock"; then
      printf 'teardown: capacity release skipped other homes for pool %s: the shared Treehouse project lock is busy\n' "$pool" >&2
      return 0
    fi
    took=1
  fi
  fm_capacity_release_oldest_elsewhere "$(dirname "$(fm_capacity_resolve_dir "$data" || printf '%s' "$data")")" "$pool" || true
  if [ -z "$FM_CAPACITY_RELEASED_ID" ] && [ -n "$fallback" ]; then
    fm_capacity_release_oldest_elsewhere "$(dirname "$(fm_capacity_resolve_dir "$data" || printf '%s' "$data")")" "$fallback" || true
  fi
  [ "$took" = 0 ] || fm_lock_release "$lock" || true
}
