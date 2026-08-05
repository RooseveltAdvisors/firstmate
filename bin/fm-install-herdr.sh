#!/usr/bin/env bash
# fm-install-herdr.sh - build CI's pinned, verified Herdr source revision.
#
# Single owner of the exact Herdr source commit used by the required real-Herdr
# CI lane. Never installs a floating package-manager latest.
#
# Usage:
#   fm-install-herdr.sh <destination-directory>
#
# Pins RooseveltAdvisors/herdr commit 30f338a3 (Herdr 0.8.0, protocol 19), the
# suite-verified generation-capable revision. Fetches only that commit, builds
# its locked dependency graph, then refuses to finish unless the binary reports
# the exact version and protocol.
set -eu

# Exact pin - change only with a re-verified real-Herdr matrix.
FM_HERDR_CI_VERSION=0.8.0
FM_HERDR_CI_PROTOCOL=19
FM_HERDR_CI_COMMIT=30f338a3794a71b405ac813998e56ea03792fccc
FM_HERDR_CI_REPO=https://github.com/RooseveltAdvisors/herdr.git

die() {
  printf 'fm-install-herdr.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-herdr.sh <destination-directory>}

TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-herdr.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
SOURCE="$TMP/source"

command -v git >/dev/null 2>&1 || die "git is required to fetch the pinned Herdr source"
command -v cargo >/dev/null 2>&1 || die "cargo is required to build the pinned Herdr source"
command -v jq >/dev/null 2>&1 || die "jq is required to verify the pinned Herdr build"

printf 'fm-install-herdr.sh: fetching %s at %s\n' \
  "$FM_HERDR_CI_REPO" "$FM_HERDR_CI_COMMIT" >&2
git init -q "$SOURCE" || die "could not initialize the temporary Herdr source checkout"
git -C "$SOURCE" remote add origin "$FM_HERDR_CI_REPO" \
  || die "could not configure the pinned Herdr source"
git -C "$SOURCE" fetch --quiet --depth 1 origin "$FM_HERDR_CI_COMMIT" \
  || die "could not fetch pinned Herdr commit $FM_HERDR_CI_COMMIT"
fetched_commit=$(git -C "$SOURCE" rev-parse FETCH_HEAD 2>/dev/null) \
  || die "could not identify the fetched Herdr commit"
[ "$fetched_commit" = "$FM_HERDR_CI_COMMIT" ] \
  || die "fetched Herdr commit $fetched_commit, expected $FM_HERDR_CI_COMMIT"
git -C "$SOURCE" checkout --quiet --detach "$FM_HERDR_CI_COMMIT" \
  || die "could not check out pinned Herdr commit $FM_HERDR_CI_COMMIT"

printf 'fm-install-herdr.sh: building pinned Herdr source\n' >&2
cargo build --locked --release --manifest-path "$SOURCE/Cargo.toml" \
  || die "could not build pinned Herdr commit $FM_HERDR_CI_COMMIT"

mkdir -p "$DESTINATION"
install -m 0755 "$SOURCE/target/release/herdr" "$DESTINATION/herdr"

# Post-build version and protocol gates (no floating latest).
installed_version=$("$DESTINATION/herdr" --version 2>/dev/null | awk '{print $2; exit}')
[ "$installed_version" = "$FM_HERDR_CI_VERSION" ] \
  || die "built herdr version is '${installed_version:-<empty>}', expected exact pin $FM_HERDR_CI_VERSION"

status=$("$DESTINATION/herdr" status --json 2>/dev/null) \
  || die "could not run 'herdr status --json' after build"
protocol=$(printf '%s' "$status" | jq -r '.client.protocol // empty' 2>/dev/null) \
  || die "could not parse herdr status after build"
case "$protocol" in
  ''|*[!0-9]*) die "could not read herdr client protocol from status --json" ;;
esac
[ "$protocol" -eq "$FM_HERDR_CI_PROTOCOL" ] \
  || die "herdr protocol $protocol does not match exact pin $FM_HERDR_CI_PROTOCOL"

printf 'fm-install-herdr.sh: built herdr %s (protocol %s) from %s to %s\n' \
  "$installed_version" "$protocol" "$FM_HERDR_CI_COMMIT" "$DESTINATION/herdr" >&2
"$DESTINATION/herdr" --version
