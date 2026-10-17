#!/usr/bin/env bash
# fm-explained-twice.sh - on-demand live-correction review, with bounded evidence.
# Usage and the complete review procedure: fm-explained-twice.sh --help
# Requires Bun; reads Pi JSONL and optional pending-reply/terminal-outcome records.
# Writes private review artifacts only, never AGENTS.md, CLAUDE.md, or skills.
# No service, watcher, model call, publication, or automatic instruction edit.
set -euo pipefail
if ! command -v bun >/dev/null 2>&1; then
  printf 'error: Bun is required to run fm-explained-twice.sh\n' >&2
  exit 1
fi
exec bun "$(dirname "${BASH_SOURCE[0]}")/fm-explained-twice.ts" "$@"
