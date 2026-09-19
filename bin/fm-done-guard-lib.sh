#!/usr/bin/env bash
# Single owner of the ship-done acceptance check: a PR-requiring ship task may
# report `done:` only after HEAD is on a remote-tracking ref and the done line,
# recorded pr=, or forge names an open PR URL. Scout, secondmate, and local-only
# (and any other mode that does not require a PR) are skipped. A missing mode
# or worktree is also skipped so incomplete fixture metadata does not change
# classification. Sourced by the watcher, away-mode daemon, crew-state reader,
# and bin/fm-done-guard.sh. No side effects on source.
# bin/fm-pr-lib.sh owns URL validation. A forge lookup is a last resort and is
# skipped when FM_DONE_GUARD_NO_FORGE=1 so callers that must stay offline can
# still refuse an unpushed or URL-less ship done.
# fm_done_guard_accepts_status_line is the classifier hook: return 0 to keep a
# done line actionable, 1 to drop it. fm_done_guard_steer_status is the watcher
# side effect that tells the worker to push.

_FM_DONE_GUARD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" \
  || _FM_DONE_GUARD_LIB_DIR="."

if ! command -v fm_pr_url_parse >/dev/null 2>&1; then
  # shellcheck source=bin/fm-pr-lib.sh
  # shellcheck disable=SC1091
  . "$_FM_DONE_GUARD_LIB_DIR/fm-pr-lib.sh"
fi

FM_DONE_GUARD_VERDICT=
FM_DONE_GUARD_REASON=

fm_done_guard_meta_field() {  # <meta> <key>
  local meta=$1 key=$2 line
  [ -f "$meta" ] && [ -r "$meta" ] || return 0
  line=$(grep -E "^${key}=" "$meta" 2>/dev/null | tail -1 || true)
  printf '%s' "${line#*=}"
}

# 0 when this kind/mode pair requires a pushed branch and an open PR.
fm_done_guard_requires_pr() {  # <kind> <mode>
  local kind=$1 mode=$2
  case "$kind" in
    scout|secondmate) return 1 ;;
  esac
  case "$mode" in
    no-mistakes|direct-PR) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 when HEAD is reachable from at least one remote-tracking ref.
fm_done_guard_head_is_pushed() {  # <worktree>
  local wt=$1 remotes unpushed
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  remotes=$(git -C "$wt" for-each-ref --format='%(refname)' refs/remotes 2>/dev/null) || remotes=
  [ -n "$remotes" ] || return 1
  unpushed=$(git -C "$wt" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -z "$unpushed" ]
}

# Print a canonical PR/MR URL found in <line>, or return 1.
fm_done_guard_pr_url_from_line() {  # <line>
  local line=$1 tok
  [ -n "$line" ] || return 1
  # shellcheck disable=SC2086  # word-split the status note into URL candidates
  for tok in $line; do
    while :; do
      case "$tok" in
        *')'|*,|*.|*';') tok=${tok%?} ;;
        *) break ;;
      esac
    done
    case "$tok" in
      https://*)
        fm_pr_url_parse "$tok" || continue
        printf '%s' "$FM_PR_URL"
        return 0
        ;;
    esac
  done
  return 1
}

fm_done_guard_pr_url_from_meta() {  # <meta>
  local meta=$1 value
  value=$(fm_done_guard_meta_field "$meta" pr)
  [ -n "$value" ] || return 1
  fm_pr_url_parse "$value" || return 1
  printf '%s' "$FM_PR_URL"
}

fm_done_guard_pr_url_from_forge() {  # <worktree>
  local wt=$1 url
  [ "${FM_DONE_GUARD_NO_FORGE:-}" = 1 ] && return 1
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  url=$(cd "$wt" && gh pr view --json url -q .url 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  fm_pr_url_parse "$url" || return 1
  printf '%s' "$FM_PR_URL"
}

# Inspect one status file and optional done line. Sets FM_DONE_GUARD_VERDICT to
# accepted, skipped, or refused and FM_DONE_GUARD_REASON to a short token.
# Return 0 for accepted or skipped, 1 for refused.
fm_done_guard_check() {  # <status-file> [<done-line>]
  local status=$1 line=${2-} meta kind mode wt
  FM_DONE_GUARD_VERDICT=skipped
  FM_DONE_GUARD_REASON=no-status
  [ -n "$status" ] || return 0
  meta=${status%.status}.meta
  kind=$(fm_done_guard_meta_field "$meta" kind)
  mode=$(fm_done_guard_meta_field "$meta" mode)
  wt=$(fm_done_guard_meta_field "$meta" worktree)
  if [ -z "$line" ]; then
    command -v last_status_line >/dev/null 2>&1 \
      && line=$(last_status_line "$status")
    [ -n "$line" ] || line=$(tail -n 1 "$status" 2>/dev/null || true)
  fi
  if ! fm_done_guard_requires_pr "$kind" "$mode"; then
    FM_DONE_GUARD_REASON=${mode:-${kind:-no-mode}}
    [ -n "$FM_DONE_GUARD_REASON" ] || FM_DONE_GUARD_REASON=no-mode
    return 0
  fi
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    FM_DONE_GUARD_REASON=no-worktree
    return 0
  fi
  if ! fm_done_guard_head_is_pushed "$wt"; then
    FM_DONE_GUARD_VERDICT=refused
    FM_DONE_GUARD_REASON=unpushed
    return 1
  fi
  if fm_done_guard_pr_url_from_line "$line" >/dev/null; then
    FM_DONE_GUARD_VERDICT=accepted
    FM_DONE_GUARD_REASON=accepted
    return 0
  fi
  if fm_done_guard_pr_url_from_meta "$meta" >/dev/null; then
    FM_DONE_GUARD_VERDICT=accepted
    FM_DONE_GUARD_REASON=accepted
    return 0
  fi
  if fm_done_guard_pr_url_from_forge "$wt" >/dev/null; then
    FM_DONE_GUARD_VERDICT=accepted
    FM_DONE_GUARD_REASON=accepted
    return 0
  fi
  FM_DONE_GUARD_VERDICT=refused
  FM_DONE_GUARD_REASON=no-pr
  return 1
}

# Classifier hook. 0 keeps the done line actionable.
fm_done_guard_accepts_status_line() {  # <status-file> <line>
  local status=$1 line=$2 verb
  command -v status_line_verb >/dev/null 2>&1 || return 0
  verb=$(status_line_verb "$line")
  [ "$verb" = "done" ] || return 0
  fm_done_guard_check "$status" "$line"
}

fm_done_guard_steer_fingerprint() {  # <line>
  local line=$1
  printf '%s' "$line" | sha256sum 2>/dev/null | awk '{print $1}' \
    || printf '%s' "$line" | shasum -a 256 2>/dev/null | awk '{print $1}' \
    || printf '%s' "$line"
}

# Steer once per distinct refused done line. Return 0 if a steer was sent or
# already recorded for this line, 1 if send failed.
fm_done_guard_steer_status() {  # <status-file> <line>
  local status=$1 line=$2 task marker fp send home state msg
  task=$(basename "$status")
  task=${task%.status}
  case "$task" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  state=$(cd "$(dirname "$status")" && pwd) || return 1
  marker="$state/${task}.done-guard-steered"
  fp=$(fm_done_guard_steer_fingerprint "$line")
  [ -n "$fp" ] || return 1
  if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null || true)" = "$fp" ]; then
    return 0
  fi
  msg="Your done report was refused: this ship task requires a pushed branch and an open PR. Push the branch to origin and open a PR, then report done with the PR's full https URL. For a no-mistakes ship, start /no-mistakes so the pipeline can push and open the PR; do not report done until it prints done: PR <url> checks green."
  send=${FM_DONE_GUARD_SEND:-$_FM_DONE_GUARD_LIB_DIR/fm-send.sh}
  home=${FM_HOME:-$(cd "$state/.." && pwd)}
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$send" "$task" "$msg"; then
    return 1
  fi
  printf '%s\n' "$fp" > "$marker" || return 1
  return 0
}

fm_done_guard_print_check() {
  printf 'verdict=%s\n' "$FM_DONE_GUARD_VERDICT"
  printf 'reason=%s\n' "$FM_DONE_GUARD_REASON"
}
