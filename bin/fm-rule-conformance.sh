#!/usr/bin/env bash
# On-demand, artifact-derived conformance logging; never gates or applies changes.
# Usage and manifest schema: fm-rule-conformance.sh --help
# Requires Bun and Git; optional GitHub collection uses gh-axi, never gh directly.
set -euo pipefail
exec bun "$(dirname "${BASH_SOURCE[0]}")/fm-rule-conformance.ts" "$@"
