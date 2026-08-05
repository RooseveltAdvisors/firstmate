#!/usr/bin/env bash
# Contract tests for the pinned Herdr / Treehouse CI fixtures and the
# bounded Herdr lab cleanup helper. These tests do not download release assets
# and never start or stop the captain's default Herdr session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HERDR_INSTALL="$ROOT/bin/fm-install-herdr.sh"
TREEHOUSE_INSTALL="$ROOT/bin/fm-install-treehouse.sh"
CLEANUP="$ROOT/bin/fm-herdr-ci-cleanup.sh"
CI="$ROOT/.github/workflows/ci.yml"

assert_present "$HERDR_INSTALL" "bin/fm-install-herdr.sh is missing"
assert_present "$TREEHOUSE_INSTALL" "bin/fm-install-treehouse.sh is missing"
assert_present "$CLEANUP" "bin/fm-herdr-ci-cleanup.sh is missing"
[ -x "$HERDR_INSTALL" ] || fail "fm-install-herdr.sh must be executable"
[ -x "$TREEHOUSE_INSTALL" ] || fail "fm-install-treehouse.sh must be executable"
[ -x "$CLEANUP" ] || fail "fm-herdr-ci-cleanup.sh must be executable"

test_herdr_installer_pins_generation_capable_source() {
  assert_grep 'FM_HERDR_CI_VERSION=0.8.0' "$HERDR_INSTALL" \
    "Herdr installer must pin suite-verified 0.8.0"
  assert_grep 'FM_HERDR_CI_PROTOCOL=19' "$HERDR_INSTALL" \
    "Herdr installer must require exact protocol 19"
  assert_grep 'FM_HERDR_CI_COMMIT=30f338a3794a71b405ac813998e56ea03792fccc' "$HERDR_INSTALL" \
    "Herdr installer must pin the generation-capable source commit"
  assert_grep 'FM_HERDR_CI_ZIG_VERSION=0.15.2' "$HERDR_INSTALL" \
    "Herdr installer must require the source-compatible Zig version"
  assert_grep 'command -v zig' "$HERDR_INSTALL" \
    "Herdr installer must fail before fetching when Zig is unavailable"
  assert_grep 'RooseveltAdvisors/herdr' "$HERDR_INSTALL" \
    "Herdr installer must use the landed Herdr source"
  assert_grep "fetch --quiet --depth 1 origin \"\$FM_HERDR_CI_COMMIT\"" "$HERDR_INSTALL" \
    "Herdr installer must fetch only the exact source commit"
  assert_grep 'cargo build --locked --release' "$HERDR_INSTALL" \
    "Herdr installer must build the locked source revision"
  assert_no_grep 'brew install' "$HERDR_INSTALL" \
    "Herdr installer must not use a floating package-manager install"
  assert_no_grep 'apt-get install' "$HERDR_INSTALL" \
    "Herdr installer must not use a floating package-manager install"
  assert_no_grep '0.7.4' "$HERDR_INSTALL" \
    "Herdr installer must not retain the incompatible legacy pin"
  pass "Herdr installer pins the exact generation-capable source and protocol"
}

test_treehouse_installer_pins_exact_version_and_checksums() {
  assert_grep 'FM_TREEHOUSE_CI_VERSION=2.0.1' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must pin the suite-verified 2.0.1 release"
  assert_grep 'kunchenguid/treehouse' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must use the official GitHub release source"
  assert_grep 'linux-amd64.tar.gz' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must name the Linux amd64 archive"
  assert_grep '1d5a32751ab921670103fd201ddb2b91b47338cb13976f45642b827cf8976af2' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must pin the Linux amd64 SHA-256"
  assert_grep '--max-filesize' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must bound the download size"
  assert_no_grep 'brew install' "$TREEHOUSE_INSTALL" \
    "Treehouse installer must not use a floating package-manager install"
  pass "Treehouse installer pins exact version, asset, and checksum"
}

test_cleanup_only_targets_job_owned_lab_sessions() {
  assert_grep 'fm-lab-' "$CLEANUP" \
    "cleanup must only consider fm-lab-* session names"
  assert_grep 'default == false' "$CLEANUP" \
    "cleanup must refuse default sessions"
  assert_grep 'snapshot' "$CLEANUP" \
    "cleanup must support a pre-suite snapshot"
  assert_grep 'teardown' "$CLEANUP" \
    "cleanup must support post-suite teardown of the delta"
  # Must not call ambient server stop.
  assert_no_grep 'server stop' "$CLEANUP" \
    "cleanup must never call ambient herdr server stop"
  pass "cleanup is bounded to job-owned fm-lab-* sessions"
}

test_ci_wires_installers_and_required_lane() {
  assert_grep 'tests-herdr:' "$CI" "CI must define the required Herdr Behavior job"
  assert_grep 'fm-install-herdr.sh' "$CI" "CI must call the Herdr installer"
  assert_grep 'Build pinned Herdr source' "$CI" "CI must build the source-pinned Herdr fixture"
  assert_grep 'uses: mlugg/setup-zig@v2' "$CI" "CI must install Zig before building Herdr"
  assert_grep 'version: 0.15.2' "$CI" "CI must pin the source-compatible Zig version"
  assert_grep 'command -v zig' "$CI" "CI must fail early when Zig setup is unavailable"
  assert_grep 'expected exact Herdr pin 0.8.0' "$CI" "CI must assert the exact Herdr version"
  assert_grep 'required pin 19' "$CI" "CI must assert exact protocol 19"
  assert_grep 'fm-install-treehouse.sh' "$CI" "CI must call the Treehouse installer"
  assert_grep 'fm-herdr-ci-cleanup.sh snapshot' "$CI" "CI must snapshot sessions before the suite"
  assert_grep 'fm-herdr-ci-cleanup.sh teardown' "$CI" "CI must teardown job-owned sessions after"
  assert_grep "fail-on-gate-skip 'herdr not found'" "$CI" \
    "CI Herdr lane must fail on herdr-not-found"
  assert_grep 'family real-herdr-gated' "$CI" \
    "CI Herdr lane must run only the real-herdr-gated family"
  assert_grep 'lane portable-parallel-1' "$CI" \
    "portable CI must run parallel shard 1"
  assert_grep 'lane portable-parallel-2' "$CI" \
    "portable CI must run parallel shard 2"
  assert_grep 'lane portable-serial' "$CI" \
    "portable CI must run the serial remainder"
  assert_grep 'fm-test-run.sh --check-coverage' "$CI" \
    "CI must prove portable lanes and Herdr partition the complete inventory"
  # Live harness credential tests must stay out of the default Herdr lane.
  assert_no_grep 'live-harness-optin' "$CI" \
    "CI must not run live-harness-optin in the required Herdr lane"
  assert_no_grep 'FM_AFK_PI_HERDR_E2E' "$CI" \
    "CI must not enable live Pi/Herdr credential tests"
  assert_no_grep 'FM_SEND_MARKER_HERDR_E2E' "$CI" \
    "CI must not enable live marker Herdr credential tests"
  pass "CI wires pinned installers into a required serial Herdr lane"
}

test_herdr_installer_pins_generation_capable_source
test_treehouse_installer_pins_exact_version_and_checksums
test_cleanup_only_targets_job_owned_lab_sessions
test_ci_wires_installers_and_required_lane
