#!/usr/bin/env bash
# Live CLI drive of bin/fm-rule-conformance.sh against disposable fixtures.
set -uo pipefail
W=$1; T=$(mktemp -d "${TMPDIR:-/tmp}/fm-rc-live.XXXXXX"); CLI="$W/bin/fm-rule-conformance.sh"
trap 'rm -rf "$T"' EXIT
ids='search-before-ask ui-done-gate watchdog auto-bead explained-twice timestamped-heads disclose-not-rewrite strip-at-merge no-waiver-merges green-claims current-head-recount two-attempt-cap refusal-verbatim no-hand-edit-enforcement fail-before-pass-after stop-at-safety-boundary no-phi-in-receipts one-worktree first-step-first report-standards never-bypass-a-refusal'
for i in $ids; do printf '| `%s` | fixture |\n' "$i"; done > "$T/registry.md"
# Real git source: the run worktree's own two most recent commits (read-only).
c1=$(git -C "$W" rev-parse HEAD); c2=$(git -C "$W" rev-parse HEAD~1)
printf '{"git":[{"repo":"%s","commits":["%s","%s"]}]}' "$W" "$c1" "$c2" > "$T/m.json"
R="$T/repo"; git init -q "$R"; git -C "$R" -c user.name=F -c user.email=f@x.invalid -c core.hooksPath=/dev/null commit -q --allow-empty -m init
run() { echo "\$ fm-rule-conformance.sh --output ${1#$T/}"; bash "$CLI" --manifest "$T/m.json" --output "$1" --registry "$T/registry.md"; echo "exit=$?"; }
echo "== S1 two-path git check-ignore -q (the root-cause git behaviour)"
echo 'data/' > "$R/.gitignore"
git -C "$R" check-ignore -q -- "$R/data/p/conformance.log" "$R/data/p/conformance-notes.md"; echo "two-path -q exit=$?"
git -C "$R" check-ignore -q -- "$R/data/p/conformance.log"; echo "single-path -q exit=$?"
echo "== S2 ignored+untracked data/ dir inside Git: collect, then rerun"
run "$R/data/p"; wc -l < "$R/data/p/conformance.log" | sed 's/^/log rows: /'; sha1=$(sha256sum "$R/data/p/conformance.log" "$R/data/p/conformance-notes.md")
run "$R/data/p"; sha2=$(sha256sum "$R/data/p/conformance.log" "$R/data/p/conformance-notes.md"); [ "$sha1" = "$sha2" ] && echo "rerun: log+notes byte-identical"
head -3 "$R/data/p/conformance.log"
echo "== S3 not-ignored data/ dir inside Git is refused"
: > "$R/.gitignore"; run "$R/data/q"; ls "$R/data/q" 2>/dev/null | sed 's/^/left: /'
echo "== S4 only conformance.log ignored (notes not) is refused"
echo 'data/*/conformance.log' > "$R/.gitignore"; run "$R/data/r"
echo "== S5 log+notes ignored but api-*.json snapshots not ignored is refused"
echo 'data/*/conformance*' > "$R/.gitignore"; run "$R/data/s"
echo "== S6 tracked output is refused"
echo 'data/' > "$R/.gitignore"; git -C "$R" add -f data/p/conformance.log; run "$R/data/p"
echo "== S7 non-Git private data/ dir works"
mkdir -p "$T/plain"; run "$T/plain/data/rc"
echo "== S8 git missing from PATH fails closed"
B="$T/bin"; mkdir "$B"; ln -s "$(command -v bun)" "$B/bun"; ln -s "$(command -v dirname)" "$B/dirname"
PATH="$B" "$(command -v bash)" "$CLI" --manifest "$T/m.json" --output "$R/data/nogit" --registry "$T/registry.md"; echo "exit=$?"; ls "$R/data/nogit" 2>/dev/null | grep -v '^$' | sed 's/^/left: /'
