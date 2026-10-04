#!/usr/bin/env bash
# Retire stale restored-shell Herdr presentation children at locked session start.
#
# Usage: fm-herdr-session-cleanup.sh
#
# The caller must already own this Firstmate home's session lock. This script is
# home-local and considers only the current named Herdr session and ordinary
# state/*.herdr-presentation journals in the effective FM_HOME. Each candidate
# is additionally serialized by the existing state/.spawn-<task>.lock and the
# shared named-session Herdr presentation lock, in that order.
#
# A visible title is discovery only. Cleanup requires the exact current
# "└ <concise-task> · p:<22-char-token>" grammar, one token occurrence across
# the named-session snapshot, exactly one matching home-local journal, one tab,
# one pane, absent task metadata, no registered agent, and a process proof that
# the pane contains only one idle recognized shell with no child process. A
# version 2 journal must also bind the exact workspace, tab, and pane.
# Topology is first checked from one locked API snapshot, then every mutation
# prerequisite is immediately rechecked before the existing exact-pane
# focus-preserving close helper is called.
# The script never closes a workspace. It removes only the matching journal,
# and only after the exact pane is confirmed gone. Every error warns and returns
# success so session startup continues conservatively.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source herdr
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

fm_herdr_cleanup_warn() {
  printf 'warning: herdr session-start projection cleanup: %s\n' "$*" >&2
  if [ "${FM_HERDR_CLEANUP_DEBUG:-0}" = 1 ]; then
    printf 'warn: %s\n' "$*" >> "${FM_HERDR_CLEANUP_DEBUG_DIR:-/tmp}/fm-cleanup-debug.log"
  fi
}

fm_herdr_cleanup_title_token() { # <workspace-title>
  local title=$1 prefix token rest
  case "$title" in
    '└ '*' · p:'*) ;;
    *) return 1 ;;
  esac
  token=${title##*' · p:'}
  prefix=${title%" · p:$token"}
  [ "$prefix" != "$title" ] && [ -n "${prefix#'└ '}" ] || return 1
  [ "${#token}" -eq 22 ] || return 1
  case "$token" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  rest=${title#*p:}
  [ "$rest" != "$title" ] || return 1
  case "$rest" in *p:*) return 1 ;; esac
  printf '%s' "$token"
}

fm_herdr_cleanup_home_identity() {
  [ -d "$FM_HOME" ] && [ ! -L "$FM_HOME" ] || return 1
  (cd "$FM_HOME" 2>/dev/null && pwd -P)
}

fm_herdr_cleanup_mtime() { # <file>
  if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null || echo 0
  else
    stat -c %Y "$1" 2>/dev/null || echo 0
  fi
}

# One-pass index of every presentation journal, built once per cleanup run.
# Fields per row: id, journal path, candidate (1/0: valid snapshot, home and
# session bound), token (projection id).
# Dead projection journals (no live workspace in Herdr references them) and
# malformed journals older than 7d are pruned here, outside every title loop.
fm_herdr_cleanup_index_file=""

fm_herdr_cleanup_index_build() { # <session> <home-real> [candidates] [deadline]
  fm_herdr_cleanup_index_file=$(mktemp "${TMPDIR:-/tmp}/fm-herdr-cleanup-index.XXXXXX") || return 1
  local session=$1 home_real=$2 candidates=${3:-} deadline=${4:-0}
  local journal id expected journal_home home_ok is_alive has_untokened_projection=0
  local age_cut pruned_count=0 pruned_ids="" mtime

  age_cut=$(( $(date +%s) - 604800 ))

  if [ -n "$candidates" ]; then
    if printf '%s\n' "$candidates" | awk -F '\t' '$2 ~ /^└ / && $2 !~ / · p:/ { found=1; exit } END { exit !found }'; then
      has_untokened_projection=1
    fi
  fi

  for journal in "$STATE"/*"$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX"; do
    [ -f "$journal" ] && [ ! -L "$journal" ] || continue
    if [ "$deadline" -gt 0 ] && [ "$SECONDS" -ge "$deadline" ]; then
      fm_herdr_cleanup_warn "projection journal index build exceeded budget; stopping early"
      break
    fi
    id=$(basename "$journal" "$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX")
    fm_task_id_creation_valid "$id" || continue

    if ! fm_backend_herdr_projection_journal_snapshot "$journal" "$id"; then
      # A journal that fails validation can never match a cleanup; prune it
      # once it is older than the retention window so accumulation stays
      # bounded. Fail-both-ways preserved: valid journals are never removed.
      if [ -z "${FM_HERDR_CLEANUP_SKIP_PRUNE:-}" ]; then
        mtime=$(fm_herdr_cleanup_mtime "$journal")
        if [ "$mtime" -gt 0 ] && [ "$mtime" -lt "$age_cut" ]; then
          rm -f -- "$journal"
          fm_herdr_cleanup_warn "$id pruned: malformed projection journal older than 7d"
        fi
      fi
      continue
    fi

    # Version 1 carries no home/session binding, so the binding check is
    # satisfied by construction; version 2 must bind the real home identity
    # and the live named session.
    home_ok=1
    if [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" = 2 ]; then
      journal_home=$(fm_backend_herdr_projection_home_identity \
        "$FM_BACKEND_HERDR_JOURNAL_HOME" 2>/dev/null) || journal_home=""
      { [ "$journal_home" = "$home_real" ] \
        && [ "$FM_BACKEND_HERDR_JOURNAL_SESSION" = "$session" ]; } || home_ok=0
    fi
    expected=$(fm_backend_herdr_projection_workspace_label \
      "$id" "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID")

    is_alive=0
    if [ -n "$candidates" ]; then
      case "$candidates" in
        *"p:$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID"*) is_alive=1 ;;
      esac
      if [ "$is_alive" -eq 0 ] && [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" = 2 ] \
        && [ -n "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID" ]; then
        case "$candidates" in
          *"$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID"$'\t'*) is_alive=1 ;;
        esac
      fi
      if [ "$is_alive" -eq 0 ] && [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" = 1 ] \
        && [ "$has_untokened_projection" -eq 1 ]; then
        is_alive=1
      fi
    else
      is_alive=1
    fi

    if [ "$is_alive" -eq 0 ]; then
      # Dead projection: no live workspace in Herdr references this projection.
      # Must bind this home and session, have no active metadata, and no spawn lock.
      if [ "$home_ok" -eq 1 ] \
        && [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] \
        && [ ! -d "$STATE/.spawn-$id.lock" ] \
        && [ -z "${FM_HERDR_CLEANUP_SKIP_PRUNE:-}" ]; then
        rm -f -- "$journal"
        pruned_count=$((pruned_count + 1))
        pruned_ids="${pruned_ids:+$pruned_ids, }$id"
      fi
      continue
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$journal" "$home_ok" "$expected" \
      "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID" >> "$fm_herdr_cleanup_index_file"
  done

  if [ "$pruned_count" -gt 0 ]; then
    fm_herdr_cleanup_warn "pruned $pruned_count dead projection journal(s): $pruned_ids"
  fi
}

fm_herdr_cleanup_index_release() {
  [ -n "$fm_herdr_cleanup_index_file" ] && rm -f -- "$fm_herdr_cleanup_index_file"
  fm_herdr_cleanup_index_file=""
}

fm_herdr_cleanup_journal_matches() { # <title> [session] [home-real]
  local title=$1
  if [ -n "$fm_herdr_cleanup_index_file" ] && [ -f "$fm_herdr_cleanup_index_file" ]; then
    awk -F '\t' -v title="$title" \
      '$4 == title && $3 == 1 \
       { print $2 "\t" $1 "\t" $5 }' \
      "$fm_herdr_cleanup_index_file" 2>/dev/null
    return 0
  fi
  local session=${2:-} home_real=${3:-} journal id expected journal_home
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  for journal in "$STATE"/*"$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX"; do
    [ -f "$journal" ] && [ ! -L "$journal" ] || continue
    id=$(basename "$journal" "$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX")
    fm_task_id_creation_valid "$id" || continue
    fm_backend_herdr_projection_journal_snapshot "$journal" "$id" || continue
    if [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" = 2 ]; then
      journal_home=$(fm_backend_herdr_projection_home_identity \
        "$FM_BACKEND_HERDR_JOURNAL_HOME" 2>/dev/null) || continue
      [ "$journal_home" = "$home_real" ] \
        && [ "$FM_BACKEND_HERDR_JOURNAL_SESSION" = "$session" ] || continue
    fi
    expected=$(fm_backend_herdr_projection_workspace_label \
      "$id" "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID")
    [ "$expected" = "$title" ] || continue
    printf '%s\t%s\t%s\n' "$journal" "$id" "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID"
  done
}

fm_herdr_cleanup_unique_match() { # <title> [session] [home-real]
  local title=$1 session=${2:-} home_real=${3:-} matches count record
  FM_HERDR_CLEANUP_JOURNAL=
  FM_HERDR_CLEANUP_ID=
  FM_HERDR_CLEANUP_TOKEN=
  FM_HERDR_CLEANUP_VERSION=
  FM_HERDR_CLEANUP_BOUND_WORKSPACE=
  FM_HERDR_CLEANUP_BOUND_TAB=
  FM_HERDR_CLEANUP_BOUND_PANE=
  matches=$(fm_herdr_cleanup_journal_matches "$title" "$session" "$home_real") || return 1
  count=$(printf '%s\n' "$matches" | awk 'NF { n++ } END { print n+0 }')
  [ "$count" -eq 1 ] || return 1
  record=$(printf '%s\n' "$matches" | awk 'NF { print; exit }')
  FM_HERDR_CLEANUP_JOURNAL=${record%%$'\t'*}
  record=${record#*$'\t'}
  FM_HERDR_CLEANUP_ID=${record%%$'\t'*}
  FM_HERDR_CLEANUP_TOKEN=${record#*$'\t'}
  [ -n "$FM_HERDR_CLEANUP_JOURNAL" ] \
    && [ -n "$FM_HERDR_CLEANUP_ID" ] \
    && [ -n "$FM_HERDR_CLEANUP_TOKEN" ] || return 1
  # Immediate re-read of the one matched journal (single pass, no rescan).
  if ! fm_backend_herdr_projection_journal_snapshot \
    "$FM_HERDR_CLEANUP_JOURNAL" "$FM_HERDR_CLEANUP_ID"; then
    return 1
  fi
  [ "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID" = "$FM_HERDR_CLEANUP_TOKEN" ] || return 1
  FM_HERDR_CLEANUP_VERSION=$FM_BACKEND_HERDR_JOURNAL_VERSION
  if [ "$FM_HERDR_CLEANUP_VERSION" = 2 ]; then
    FM_HERDR_CLEANUP_BOUND_WORKSPACE=$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID
    FM_HERDR_CLEANUP_BOUND_TAB=$FM_BACKEND_HERDR_JOURNAL_TAB_ID
    FM_HERDR_CLEANUP_BOUND_PANE=$FM_BACKEND_HERDR_JOURNAL_PANE_ID
  fi
}

fm_herdr_cleanup_snapshot_candidate() { # <snapshot> <workspace> <title> <token> <bound-workspace> <bound-tab> <bound-pane>
  local snapshot=$1 workspace=$2 title=$3 token=$4
  local bound_workspace=$5 bound_tab=$6 bound_pane=$7 record
  FM_HERDR_CLEANUP_TAB=
  FM_HERDR_CLEANUP_PANE=
  record=$(printf '%s' "$snapshot" | jq -er \
    --arg workspace "$workspace" --arg title "$title" --arg token "$token" \
    --arg bound_workspace "$bound_workspace" --arg bound_tab "$bound_tab" \
    --arg bound_pane "$bound_pane" '
    .result.snapshot as $s
    | [$s.workspaces[]? | select(.workspace_id == $workspace)] as $workspaces
    | [$s.tabs[]? | select(.workspace_id == $workspace)] as $tabs
    | [$s.panes[]? | select(.workspace_id == $workspace)] as $panes
    | ([ $s.workspaces[]?.label? // "" |
         ((split("p:" + $token) | length) - 1) ] | add // 0) as $token_count
    | select($workspaces | length == 1)
    | select($workspaces[0].label == $title)
    | select($workspaces[0].tab_count == 1 and $workspaces[0].pane_count == 1)
    | select($tabs | length == 1)
    | select($panes | length == 1)
    | select($panes[0].tab_id == $tabs[0].tab_id)
    | select($bound_workspace == "" or $workspace == $bound_workspace)
    | select($bound_tab == "" or $tabs[0].tab_id == $bound_tab)
    | select($bound_pane == "" or $panes[0].pane_id == $bound_pane)
    | select($token_count == 1)
    | select(($s.focused_workspace_id | type) == "string")
    | select(($s.focused_tab_id | type) == "string")
    | select(($s.focused_pane_id | type) == "string")
    | select($s.focused_tab_id != $tabs[0].tab_id)
    | [$tabs[0].tab_id, $panes[0].pane_id] | @tsv
  ' 2>/dev/null) || return 1
  [ -n "$record" ] && [ "${record#*$'\t'}" != "$record" ] || return 1
  FM_HERDR_CLEANUP_TAB=${record%%$'\t'*}
  FM_HERDR_CLEANUP_PANE=${record#*$'\t'}
  [ -n "$FM_HERDR_CLEANUP_TAB" ] && [ -n "$FM_HERDR_CLEANUP_PANE" ]
}

fm_herdr_cleanup_revalidate() { # <session> <workspace> <tab> <pane> <title> <token> <home-real> <journal> <task-id> <version> <bound-workspace> <bound-tab> <bound-pane>
  local session=$1 workspace=$2 tab=$3 pane=$4 title=$5 token=$6 home_real=$7
  local journal=$8 id=$9 version=${10} bound_workspace=${11} bound_tab=${12} bound_pane=${13}
  local workspaces workspace_info tabs panes focus
  [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || return 1
  fm_herdr_cleanup_unique_match "$title" "$session" "$home_real" || return 1
  [ "$FM_HERDR_CLEANUP_JOURNAL" = "$journal" ] \
    && [ "$FM_HERDR_CLEANUP_ID" = "$id" ] \
    && [ "$FM_HERDR_CLEANUP_TOKEN" = "$token" ] \
    && [ "$FM_HERDR_CLEANUP_VERSION" = "$version" ] \
    && [ "$FM_HERDR_CLEANUP_BOUND_WORKSPACE" = "$bound_workspace" ] \
    && [ "$FM_HERDR_CLEANUP_BOUND_TAB" = "$bound_tab" ] \
    && [ "$FM_HERDR_CLEANUP_BOUND_PANE" = "$bound_pane" ] || return 1

  workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$workspaces" | jq -e --arg workspace "$workspace" --arg title "$title" --arg token "$token" '
    ([.result.workspaces[]? | select(.workspace_id == $workspace and .label == $title)] | length) == 1
    and ([.result.workspaces[]?.label? // "" |
          ((split("p:" + $token) | length) - 1)] | add // 0) == 1
  ' >/dev/null 2>&1 || return 1
  workspace_info=$(fm_backend_herdr_cli "$session" workspace get "$workspace" 2>/dev/null) || return 1
  printf '%s' "$workspace_info" | jq -e --arg workspace "$workspace" --arg title "$title" '
    .result.workspace.workspace_id == $workspace
    and .result.workspace.label == $title
    and .result.workspace.tab_count == 1
    and .result.workspace.pane_count == 1
  ' >/dev/null 2>&1 || return 1
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e --arg workspace "$workspace" --arg tab "$tab" '
    (.result.tabs | type) == "array"
    and (.result.tabs | length) == 1
    and .result.tabs[0].workspace_id == $workspace
    and .result.tabs[0].tab_id == $tab
  ' >/dev/null 2>&1 || return 1
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -e --arg workspace "$workspace" --arg tab "$tab" --arg pane "$pane" '
    (.result.panes | type) == "array"
    and (.result.panes | length) == 1
    and .result.panes[0].workspace_id == $workspace
    and .result.panes[0].tab_id == $tab
    and .result.panes[0].pane_id == $pane
  ' >/dev/null 2>&1 || return 1
  [ "$(fm_backend_herdr_pane_agent_state "$session" "$pane")" = no-agent ] || return 1
  fm_backend_herdr_pane_idle_shell_pid "$session" "$pane" >/dev/null || return 1
  focus=$(fm_backend_herdr_projection_focus_snapshot "$session") || return 1
  [ "${focus#*$'\t'}" != "$tab" ]
}

fm_herdr_cleanup_one() { # <session> <workspace> <title> <home-real>
  local session=$1 workspace=$2 title=$3 home_real=$4 token journal id task_lock
  local version bound_workspace bound_tab bound_pane presentation_lock snapshot
  local tab pane state close_status=0
  token=$(fm_herdr_cleanup_title_token "$title") || return 0
  if ! fm_herdr_cleanup_unique_match "$title" "$session" "$home_real"; then
    return 0
  fi
  journal=$FM_HERDR_CLEANUP_JOURNAL
  id=$FM_HERDR_CLEANUP_ID
  version=$FM_HERDR_CLEANUP_VERSION
  bound_workspace=$FM_HERDR_CLEANUP_BOUND_WORKSPACE
  bound_tab=$FM_HERDR_CLEANUP_BOUND_TAB
  bound_pane=$FM_HERDR_CLEANUP_BOUND_PANE
  [ "$FM_HERDR_CLEANUP_TOKEN" = "$token" ] || return 0
  task_lock="$STATE/.spawn-$id.lock"
  if ! fm_lock_try_acquire "$task_lock"; then
    fm_herdr_cleanup_warn "$id skipped because its task lock is busy"
    return 0
  fi
  presentation_lock=$(fm_backend_herdr_presentation_session_lock_path "$session" 2>/dev/null) || {
    fm_lock_release "$task_lock" || true
    fm_herdr_cleanup_warn "$id skipped because the shared presentation lock is unavailable"
    return 0
  }
  if ! fm_lock_try_acquire "$presentation_lock"; then
    fm_lock_release "$task_lock" || true
    fm_herdr_cleanup_warn "$id skipped because the shared presentation lock is busy"
    return 0
  fi

  if [ -e "$STATE/$id.meta" ] || [ -L "$STATE/$id.meta" ]; then
    fm_lock_release "$presentation_lock" || true
    fm_lock_release "$task_lock" || true
    return 0
  fi
  snapshot=$(fm_backend_herdr_cli "$session" api snapshot 2>/dev/null) || snapshot=
  if [ -z "$snapshot" ] \
    || ! fm_herdr_cleanup_snapshot_candidate \
      "$snapshot" "$workspace" "$title" "$token" \
      "$bound_workspace" "$bound_tab" "$bound_pane"; then
    fm_herdr_cleanup_warn "$id preserved because its locked candidate snapshot was ambiguous"
    fm_lock_release "$presentation_lock" || true
    fm_lock_release "$task_lock" || true
    return 0
  fi
  tab=$FM_HERDR_CLEANUP_TAB
  pane=$FM_HERDR_CLEANUP_PANE
  if [ "$(fm_backend_herdr_pane_agent_state "$session" "$pane")" != no-agent ] \
    || ! fm_backend_herdr_pane_idle_shell_pid "$session" "$pane" >/dev/null; then
    fm_herdr_cleanup_warn "$id preserved because its pane is not a provably idle childless shell"
    fm_lock_release "$presentation_lock" || true
    fm_lock_release "$task_lock" || true
    return 0
  fi
  if ! fm_herdr_cleanup_revalidate \
    "$session" "$workspace" "$tab" "$pane" "$title" "$token" "$home_real" \
    "$journal" "$id" "$version" "$bound_workspace" "$bound_tab" "$bound_pane"; then
    fm_herdr_cleanup_warn "$id preserved because immediate revalidation changed or was unreadable"
    fm_lock_release "$presentation_lock" || true
    fm_lock_release "$task_lock" || true
    return 0
  fi

  # This unconditional retirement is the authorized containment documented
  # with the presentation floor ownership in bin/backends/herdr.sh.
  fm_backend_herdr_projection_close_pane_focus_preserving \
    "$session" "$pane" no-agent || close_status=$?
  state=$(fm_backend_herdr_pane_agent_state "$session" "$pane")
  if [ "$state" = dead ]; then
    if [ -f "$journal" ] && [ ! -L "$journal" ] \
      && fm_herdr_cleanup_unique_match "$title" "$session" "$home_real" \
      && [ "$FM_HERDR_CLEANUP_JOURNAL" = "$journal" ] \
      && [ "$FM_HERDR_CLEANUP_ID" = "$id" ] \
      && [ "$FM_HERDR_CLEANUP_VERSION" = "$version" ] \
      && [ "$FM_HERDR_CLEANUP_BOUND_WORKSPACE" = "$bound_workspace" ] \
      && [ "$FM_HERDR_CLEANUP_BOUND_TAB" = "$bound_tab" ] \
      && [ "$FM_HERDR_CLEANUP_BOUND_PANE" = "$bound_pane" ] \
      && [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ]; then
      rm -f -- "$journal" || fm_herdr_cleanup_warn "$id pane closed but its journal could not be retired"
    else
      fm_herdr_cleanup_warn "$id pane closed but its journal changed and was preserved"
    fi
  elif [ "$close_status" -ne 0 ]; then
    fm_herdr_cleanup_warn "$id preserved because exact focus-safe pane closure was refused or unconfirmed"
  else
    fm_herdr_cleanup_warn "$id preserved because exact pane closure could not be confirmed"
  fi
  fm_lock_release "$presentation_lock" || true
  fm_lock_release "$task_lock" || true
  return 0
}

fm_herdr_session_cleanup() {
  local session home_real list candidates workspace title journal found=0
  local deadline
  deadline=$((SECONDS + ${FM_HERDR_CLEANUP_BUDGET_SECS:-30}))
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  for journal in "$STATE"/*"$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX"; do
    if [ -f "$journal" ] && [ ! -L "$journal" ]; then
      found=1
      break
    fi
  done
  [ "$found" -eq 1 ] || return 0
  command -v herdr >/dev/null 2>&1 \
    && command -v jq >/dev/null 2>&1 || return 0
  home_real=$(fm_herdr_cleanup_home_identity) || {
    fm_herdr_cleanup_warn 'home identity is unreadable; preserving every candidate'
    return 0
  }
  session=$(fm_backend_herdr_session)
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || {
    fm_herdr_cleanup_warn "session '$session' workspace discovery failed; preserving every candidate"
    return 0
  }
  candidates=$(printf '%s' "$list" | jq -er '
    .result.workspaces
    | select(type == "array")
    | .[]
    | select((.workspace_id | type) == "string" and (.workspace_id | length) > 0)
    | select((.label | type) == "string" and (.label | length) > 0)
    | [.workspace_id, .label] | @tsv
  ' 2>/dev/null) || {
    fm_herdr_cleanup_warn "session '$session' workspace discovery was unreadable; preserving every candidate"
    return 0
  }
  fm_herdr_cleanup_index_build "$session" "$home_real" "$candidates" "$deadline" || {
    fm_herdr_cleanup_warn 'projection journal index could not be built; preserving every candidate'
    return 0
  }
  while IFS=$'\t' read -r workspace title; do
    [ -n "$workspace" ] && [ -n "$title" ] || continue
    if [ "$SECONDS" -ge "$deadline" ]; then
      fm_herdr_cleanup_warn "candidate cleanup loop exceeded budget (${FM_HERDR_CLEANUP_BUDGET_SECS:-30}s); stopping early"
      break
    fi
    fm_herdr_cleanup_debug_dump "$session" "$home_real"
    fm_herdr_cleanup_one "$session" "$workspace" "$title" "$home_real"
  done <<< "$candidates"
  fm_herdr_cleanup_index_release
  return 0
}

fm_herdr_cleanup_debug_dump() {
  [ "${FM_HERDR_CLEANUP_DEBUG:-0}" = 1 ] || return 0
  local dump=${FM_HERDR_CLEANUP_DEBUG_DIR:-/tmp}/fm-cleanup-debug.log
  {
    echo "=== cleanup run $(date -u +%FT%TZ) session=$1 home=$2"
    echo "index file: $fm_herdr_cleanup_index_file"
    cat "$fm_herdr_cleanup_index_file" 2>/dev/null
  } >> "$dump"
}

if [ "${FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY:-0}" != 1 ]; then
  fm_herdr_session_cleanup
  exit 0
fi
