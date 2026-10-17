#!/usr/bin/env bash
# fm-transcript-search.sh - optional read-only, bounded transcript lookup.
# Usage, bounds, result schema and limitations: fm-transcript-search.sh --help
# Requires Bun and rg. No state, index, service, or permission gate.
# Missing tools and search failures report unavailable coverage and return 0.
set -euo pipefail
if ! command -v bun >/dev/null 2>&1; then
  printf '%s\n' '{"status":"unavailable","reason":"could not search transcripts: Bun is unavailable; ask sooner"}'
  exit 0
fi
script_dir=${BASH_SOURCE[0]%/*}
[ "$script_dir" != "${BASH_SOURCE[0]}" ] || script_dir=.
exec bun "$script_dir/fm-transcript-search.ts" "$@"
