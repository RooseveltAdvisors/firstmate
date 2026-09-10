#!/usr/bin/env bash
# fm-herdr-recovery.sh - fleet-wide post-restart Herdr seat recovery.
#
# Usage:
#   fm-herdr-recovery.sh [--home <FM_HOME>] [--dry-run] [--max-rounds N]
#   fm-herdr-recovery.sh --help
#
# After a Herdr server or firstmate harness update restart, every live codex
# seat can re-present its directory trust dialog and then chain one
# command-approval prompt per recovery read. This tool inventories the invoking
# home's recorded seats (state/<id>.meta with backend=herdr), reads each pane's
# live agent_status, and for blocked codex seats accepts the directory trust
# dialog and approves only prompts whose visible command matches a bounded
# recovery-read allowlist. One round is one prompt read plus at most one Enter;
# --max-rounds (default 5) caps both the rounds and the total Enters per seat.
# The tool only ever sends Enter (which accepts the highlighted first option);
# it never types 'p' (don't-ask-again), never answers a prompt it cannot
# classify, and never touches a pane this home's metadata does not bind to one
# of its own task ids. Per-seat judgment beyond pane input belongs to the
# stuck-crewmate-recovery playbook, not this tool.
#
# Per-seat classification:
#   working        no action.
#   idle/done      report only; a healthy idle persistent seat is never relaunched.
#   blocked        codex trust/approval recovery loop.
#   other          report only.
#   no pane        report only.
#   unverifiable   metadata lacks a provable herdr seat binding; report only, never touched.
#
# Prompt classification (fail closed; every unclassified prompt is needs-human):
#   trust      "Do you trust the contents of this directory?" (live-verified on
#              codex-cli 0.153.4 over herdr 0.9.0). Add patterns only with the
#              same quality of live evidence; an unverified pattern is a
#              blind-Enter risk.
#   approval   an approval question signal ("Yes, proceed", "Would you like to
#              run the following command?", "Yes, and don't ask again"); the
#              command text between the last question line and the next
#              numbered option line must then pass the allowlist.
#   anything else   needs-human; the seat is left untouched.
#
# Allowlist: file-read commands only (cat sed ls head tail grep rg wc find awk
# echo printf sort uniq plus for/while/if shells over them; every shell segment
# head must be an allowed word), every path confined to this home's tree
# (absolute under FM_HOME, relative without "..", no "~", or /dev/null), no
# write redirects, and no deny word in the command text - credentials,
# 1Password/op, tokens/secrets, git, package installs, network or process
# tools, other agent CLIs, or anything mutating. Herdr/tmux/zellij/cmux are
# not allowlisted command words, so lifecycle commands are refused by the
# allowlist itself. Any mismatch refuses the seat as needs-human.
#
# Output: one line per seat (seat, harness, pane, before/after state, Enters
# sent, verdict) plus a summary line. Exit codes: 0 all seats resolved or
# reported no-action; 1 usage or environment error; 2 at least one seat is
# needs-human (unrecognized or refused prompt, round cap, unverifiable metadata).
#
# Tunables (environment): FM_HERDR_RECOVERY_SETTLE seconds between polls after
# an Enter (default 1) and FM_HERDR_RECOVERY_WAIT total seconds to wait for a
# status or prompt change after an Enter (default 5). Both exist so tests can
# run with zero delays.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

DRY_RUN=0
MAX_ROUNDS=5
FM_HERDR_RECOVERY_SETTLE="${FM_HERDR_RECOVERY_SETTLE:-1}"
FM_HERDR_RECOVERY_WAIT="${FM_HERDR_RECOVERY_WAIT:-5}"

FM_RECO_ALLOW_WORDS=' cat sed ls head tail grep rg wc find awk echo printf sort uniq timeout for while if in do done then else fi true '
FM_RECO_DENY_RE='(^|[^A-Za-z0-9_])(git|rm|rmdir|sudo|curl|wget|chmod|chown|chgrp|kill|pkill|ssh|scp|sftp|1password|op|credential|token|secret|passwd|push|pull|force|merge|rebase|commit|npm|npx|pnpm|yarn|pip|brew|apt|dnf|install|uninstall|mv|cp|ln|touch|tee|dd|bash|zsh|fish|dash|python|node|bun|deno|perl|ruby|php|lua|eval|exec|xargs|claude|codex|gemini|grok|kimi|cursor|no-mistakes)([^A-Za-z0-9_]|$)'

FM_RECO_AFTER=
FM_RECO_ENTERS=0
FM_RECO_VERDICT=
FM_RECO_STATUSES=

fm_reco_error() {
  printf 'error: fm-herdr-recovery: %s\n' "$*" >&2
}

fm_reco_usage() {
  sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fm_reco_meta_get() { # <key> <meta-file>
  local key=$1 value=
  [ -f "$2" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) value=${line#*=} ;;
    esac
  done < "$2" 2>/dev/null || true
  printf '%s' "$value"
}

# Every herdr call carries the recorded session explicitly; the invoking
# home's own metadata is the only source of seats this tool may drive.
fm_reco_herdr() { # <session> <herdr arguments...>
  local session=$1
  shift
  HERDR_SESSION="$session" herdr "$@" --session "$session"
}

fm_reco_pane_statuses() { # <session> -> "pane<TAB>status" lines
  local out
  out=$(fm_reco_herdr "$1" pane list 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '.result.panes[]? | "\(.pane_id)\t\(.agent_status // "none")"' 2>/dev/null
}

fm_reco_pane_status() { # <session> <pane>
  local out
  out=$(fm_reco_herdr "$1" pane get "$2" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '.result.pane.agent_status // "none"' 2>/dev/null
}

fm_reco_prompt() { # <session> <pane>
  fm_reco_herdr "$1" pane read "$2" --lines 40 2>/dev/null
}

fm_reco_send_enter() { # <session> <pane>
  fm_reco_herdr "$1" pane send-keys "$2" enter >/dev/null 2>&1
}

fm_reco_is_allowed_word() { # <word>
  case "$FM_RECO_ALLOW_WORDS" in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# fm_reco_command_words: print the first word of every shell segment of <line>.
# Separators and shell structure words become line breaks so each segment head
# is the word that would actually execute. A "timeout <duration> <cmd>" head
# also emits the wrapped command word.
fm_reco_command_words() { # <line>
  local nl=$'\n' s seg cmdsub word rest dur
  cmdsub="\$("
  s=" $1 "
  s=${s//;/"$nl"}
  s=${s//&/"$nl"}
  s=${s//|/"$nl"}
  s=${s//"$cmdsub"/"$nl"}
  s=${s//\`/"$nl"}
  s=${s//'('/"$nl"}
  s=${s//')'/"$nl"}
  s=${s//' do '/"$nl"}
  s=${s//' then '/"$nl"}
  s=${s//' else '/"$nl"}
  while IFS= read -r seg; do
    seg=${seg#"${seg%%[![:space:]]*}"}
    seg=${seg%\"}; seg=${seg#\"}
    seg=${seg%\'}; seg=${seg#\'}
    [ -n "$seg" ] || continue
    word=${seg%%[[:space:]]*}
    printf '%s\n' "$word"
    if [ "$word" = timeout ]; then
      rest=${seg#"$word"}
      rest=${rest#"${rest%%[![:space:]]*}"}
      dur=${rest%%[[:space:]]*}
      case "$dur" in
        [0-9]*[a-z]) rest=${rest#"$dur"} ;;
        [0-9]*) rest=${rest#"$dur"} ;;
      esac
      rest=${rest#"${rest%%[![:space:]]*}"}
      [ -n "$rest" ] && printf '%s\n' "${rest%%[[:space:]]*}"
    fi
  done <<< "$s"
}

# fm_reco_paths_ok: every path-like token in <text> stays inside <home>.
fm_reco_paths_ok() { # <text> <home>
  local home=$2 tok
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    case "$tok" in
      *'..'*) return 1 ;;
      '~'*) return 1 ;;
      *'://'*) return 1 ;;
      /*)
        case "$tok" in
          "$home"/*|/dev/null) ;;
          *) return 1 ;;
        esac
        ;;
    esac
  done < <(printf '%s' "$1" | grep -oE '[^[:space:]"'"'"']*/[^[:space:]"'"'"']*')
  return 0
}

# fm_reco_command_allowed: verdict over one command text (possibly multi-line).
# Prints "ok" or "refuse:<reason>".
fm_reco_command_allowed() { # <command-text> <home>
  local text=$1 home=$2 line word words red
  if [ -z "$text" ]; then
    printf 'refuse:no command text found between the question and the options'
    return 0
  fi
  if printf '%s\n' "$text" | grep -iqE "$FM_RECO_DENY_RE"; then
    printf 'refuse:command names a denied tool or topic'
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *'>>'*)
        printf 'refuse:command contains an append redirect'
        return 0
        ;;
    esac
    red=$(printf '%s' "$line" | grep -oE '>[[:space:]]*[^[:space:]]+' | grep -vE '^>[[:space:]]*(/dev/null|&1|&2)$') || red=
    if [ -n "$red" ]; then
      printf 'refuse:command writes with a redirect'
      return 0
    fi
    words=$(fm_reco_command_words "$line")
    if [ -z "$words" ]; then
      printf 'refuse:could not parse command segments'
      return 0
    fi
    while IFS= read -r word; do
      [ -n "$word" ] || continue
      fm_reco_is_allowed_word "$word" || {
        printf 'refuse:command segment "%s" is outside the read allowlist' "$word"
        return 0
      }
    done <<< "$words"
    fm_reco_paths_ok "$line" "$home" || {
      printf 'refuse:command reaches a path outside this home'
      return 0
    }
  done <<< "$text"
  printf 'ok'
  return 0
}

# fm_reco_classify_prompt <prompt> <home> -> one of:
#   trust | approve | refuse:<reason> | unknown
fm_reco_classify_prompt() { # <prompt> <home>
  local prompt=$1 home=$2 qline qno text verdict
  # The last question line, never a numbered option line carrying the same words.
  qline=$(printf '%s\n' "$prompt" \
    | grep -inE 'yes, proceed|would you like to run the following command|yes, and don.t ask again' \
    | grep -vE '^[0-9]+:[^a-zA-Z0-9]*[0-9]+[.)]' \
    | tail -1) || qline=
  if [ -n "$qline" ]; then
    qno=${qline%%:*}
    # The command block between the question and the first numbered option,
    # minus codex's Environment/Reason context lines and blank or border lines.
    text=$(printf '%s\n' "$prompt" \
      | sed -n "$((qno + 1)),\$p" \
      | sed -E '/^[^a-zA-Z0-9]*[0-9]+[.)]/q' \
      | sed -E '$d' \
      | sed -E 's/^[[:space:]]*\$[[:space:]]//' \
      | grep -vE '^[^[:alnum:]]*$|^[[:space:]]*(Environment|Reason):') || text=
    verdict=$(fm_reco_command_allowed "$text" "$home")
    case "$verdict" in
      ok) printf 'approve' ;;
      *) printf '%s' "$verdict" ;;
    esac
    return 0
  fi
  if printf '%s\n' "$prompt" | grep -qiF 'Do you trust the contents of this directory?'; then
    printf 'trust'
    return 0
  fi
  printf 'unknown'
}

# fm_reco_wait_change: after an Enter, poll until the status leaves blocked or
# the prompt changes; return 1 when neither happens within the wait budget.
fm_reco_wait_change() { # <session> <pane> <prev-prompt>
  local session=$1 pane=$2 prev=$3 polls i status prompt
  polls=1
  if [ "$FM_HERDR_RECOVERY_SETTLE" -ge 1 ]; then
    polls=$((FM_HERDR_RECOVERY_WAIT / FM_HERDR_RECOVERY_SETTLE))
    [ "$polls" -ge 1 ] || polls=1
  fi
  i=0
  while [ "$i" -lt "$polls" ]; do
    [ "$FM_HERDR_RECOVERY_SETTLE" -ge 1 ] && sleep "$FM_HERDR_RECOVERY_SETTLE"
    i=$((i + 1))
    status=$(fm_reco_pane_status "$session" "$pane") || status=none
    case "$status" in
      blocked) ;;
      *) return 0 ;;
    esac
    prompt=$(fm_reco_prompt "$session" "$pane")
    [ "$prompt" != "$prev" ] && return 0
  done
  return 1
}

# fm_reco_recover_seat: the capped trust/approval loop for one blocked codex
# seat. Sets FM_RECO_AFTER, FM_RECO_ENTERS, and FM_RECO_VERDICT.
fm_reco_recover_seat() { # <session> <pane>
  local session=$1 pane=$2 round=0 status prompt verdict
  FM_RECO_AFTER=
  FM_RECO_ENTERS=0
  FM_RECO_VERDICT=
  while [ "$round" -lt "$MAX_ROUNDS" ]; do
    status=$(fm_reco_pane_status "$session" "$pane") || status=none
    case "$status" in
      blocked) ;;
      *) FM_RECO_AFTER=$status; FM_RECO_VERDICT=recovered; return 0 ;;
    esac
    prompt=$(fm_reco_prompt "$session" "$pane")
    verdict=$(fm_reco_classify_prompt "$prompt" "$FM_HOME")
    case "$verdict" in
      trust|approve) ;;
      refuse:*)
        FM_RECO_AFTER=blocked
        FM_RECO_VERDICT="needs-human:${verdict#refuse:}"
        return 0
        ;;
      *)
        FM_RECO_AFTER=blocked
        FM_RECO_VERDICT='needs-human:unrecognized prompt'
        return 0
        ;;
    esac
    round=$((round + 1))
    if [ "$DRY_RUN" -eq 1 ]; then
      FM_RECO_ENTERS=$((FM_RECO_ENTERS + 1))
      FM_RECO_AFTER=blocked
      FM_RECO_VERDICT="dry-run:would send Enter for the $verdict prompt"
      return 0
    fi
    fm_reco_send_enter "$session" "$pane" || {
      FM_RECO_AFTER=blocked
      FM_RECO_VERDICT='needs-human:Enter could not be delivered'
      return 0
    }
    FM_RECO_ENTERS=$((FM_RECO_ENTERS + 1))
    fm_reco_wait_change "$session" "$pane" "$prompt" || {
      FM_RECO_AFTER=blocked
      FM_RECO_VERDICT="needs-human:seat did not advance within ${FM_HERDR_RECOVERY_WAIT}s after Enter"
      return 0
    }
  done
  status=$(fm_reco_pane_status "$session" "$pane") || status=none
  FM_RECO_AFTER=$status
  if [ "$status" = blocked ]; then
    FM_RECO_VERDICT="needs-human:round cap ($MAX_ROUNDS) reached with the seat still blocked"
  else
    FM_RECO_VERDICT=recovered
  fi
  return 0
}

fm_reco_main() {
  local id meta backend harness session pane binding window
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home)
        [ "$#" -ge 2 ] || { fm_reco_error '--home needs a directory'; exit 1; }
        FM_HOME=$2
        STATE=$FM_HOME/state
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --max-rounds)
        [ "$#" -ge 2 ] || { fm_reco_error '--max-rounds needs a number'; exit 1; }
        case "$2" in
          ''|*[!0-9]*) fm_reco_error '--max-rounds needs a positive integer'; exit 1 ;;
        esac
        [ "$2" -ge 1 ] || { fm_reco_error '--max-rounds needs a positive integer'; exit 1; }
        MAX_ROUNDS=$2
        shift 2
        ;;
      -h|--help)
        fm_reco_usage
        exit 0
        ;;
      *)
        fm_reco_error "unknown argument: $1"
        exit 1
        ;;
    esac
  done
  command -v herdr >/dev/null 2>&1 || { fm_reco_error 'herdr is required'; exit 1; }
  command -v jq >/dev/null 2>&1 || { fm_reco_error 'jq is required'; exit 1; }
  [ -d "$STATE" ] || { fm_reco_error "no state directory at $STATE"; exit 1; }

  local total=0 recovered=0 needs_human=0 no_action=0
  local cached_session=
  FM_RECO_STATUSES=$(mktemp) || { fm_reco_error 'could not create a temp file'; exit 1; }
  trap 'rm -f "$FM_RECO_STATUSES"' EXIT
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    backend=$(fm_reco_meta_get backend "$meta")
    [ "$backend" = herdr ] || continue
    id=${meta##*/}
    id=${id%.meta}
    total=$((total + 1))
    harness=$(fm_reco_meta_get harness "$meta")
    session=$(fm_reco_meta_get herdr_session "$meta")
    pane=$(fm_reco_meta_get herdr_pane_id "$meta")
    binding=$(fm_reco_meta_get endpoint_task_id "$meta")
    window=$(fm_reco_meta_get window "$meta")
    if [ -z "$session" ] || [ -z "$pane" ] || [ "$binding" != "$id" ] \
      || [ "$window" != "$session:$pane" ]; then
      needs_human=$((needs_human + 1))
      printf 'seat %s harness=%s pane=- before=- after=- enters=0 needs-human:metadata lacks a provable herdr seat binding\n' "$id" "${harness:-none}"
      continue
    fi
    if [ "$cached_session" != "$session" ]; then
      if ! fm_reco_pane_statuses "$session" > "$FM_RECO_STATUSES"; then
        fm_reco_error "could not read pane states from herdr session $session"
        exit 1
      fi
      cached_session=$session
    fi
    local seat_status
    seat_status=$(awk -F'\t' -v pane="$pane" '$1 == pane { print $2; exit }' "$FM_RECO_STATUSES")
    if [ -z "$seat_status" ]; then
      no_action=$((no_action + 1))
      printf 'seat %s harness=%s pane=%s before=- after=- enters=0 no-pane\n' "$id" "${harness:-none}" "$window"
      continue
    fi
    case "$seat_status" in
      working|idle|done)
        no_action=$((no_action + 1))
        printf 'seat %s harness=%s pane=%s before=%s after=%s enters=0 no-action:%s\n' "$id" "${harness:-none}" "$window" "$seat_status" "$seat_status" "$seat_status"
        continue
        ;;
      blocked) ;;
      *)
        no_action=$((no_action + 1))
        printf 'seat %s harness=%s pane=%s before=%s after=%s enters=0 no-action:status %s is not auto-recoverable\n' "$id" "${harness:-none}" "$window" "$seat_status" "$seat_status" "$seat_status"
        continue
        ;;
    esac
    if [ "$harness" != codex ]; then
      needs_human=$((needs_human + 1))
      printf 'seat %s harness=%s pane=%s before=blocked after=blocked enters=0 needs-human:blocked harness %s is not auto-recoverable\n' "$id" "${harness:-none}" "$window" "${harness:-none}"
      continue
    fi
    fm_reco_recover_seat "$session" "$pane"
    case "$FM_RECO_VERDICT" in
      recovered) recovered=$((recovered + 1)) ;;
      dry-run:*) no_action=$((no_action + 1)) ;;
      *) needs_human=$((needs_human + 1)) ;;
    esac
    printf 'seat %s harness=codex pane=%s before=blocked after=%s enters=%s %s\n' \
      "$id" "$window" "${FM_RECO_AFTER:-unknown}" "$FM_RECO_ENTERS" "$FM_RECO_VERDICT"
  done
  printf 'summary: seats=%s recovered=%s needs-human=%s no-action=%s\n' \
    "$total" "$recovered" "$needs_human" "$no_action"
  [ "$needs_human" -eq 0 ] && exit 0
  exit 2
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_reco_main "$@"
fi
