#!/usr/bin/env bash
# Evidence driver: build stubs with the consolidated tests/fixtures.sh
# fm_test_fake_tasks_axi builder and drive the REAL production capability gate
# bin/fm-tasks-axi-lib.sh (fm_tasks_axi_compatible) against them.
# Observable contract: full-capability stub accepted, floor-violating and
# reduced-capability stubs refused, and the shared fixture floor equals the
# production floor FM_TASKS_AXI_MIN.
set -u
REPO=${1:?repo}
. "$REPO/tests/fixtures.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/fm-gate.XXXXXX")
trap 'rm -rf "$work"' EXIT

probe() {  # <fakebin> <label>
  local fb=$1 label=$2 out rc
  out=$(env PATH="$fb:$PATH" bash -c '
    . "$1/bin/fm-tasks-axi-lib.sh"
    FM_TASKS_AXI_COMPATIBLE_MEMO=
    if fm_tasks_axi_compatible; then echo compatible; else echo incompatible; fi
  ' _ "$REPO" 2>&1)
  rc=$?
  printf 'probe[%s]: rc=%s result=%s\n' "$label" "$rc" "$out"
}

# 1. default full-capability stub (shared version constant) -> must be accepted
mkdir -p "$work/full"
fm_test_fake_tasks_axi "$work/full"
probe "$work/full" "full-capability default"

# 2. version below the production floor -> must be refused
mkdir -p "$work/old"
fm_test_fake_tasks_axi "$work/old" 0.2.5 yes yes
probe "$work/old" "version 0.2.5 below floor"

# 3. on-floor version but --archive-body capability missing -> must be refused
mkdir -p "$work/noarch"
fm_test_fake_tasks_axi "$work/noarch" 0.2.6 no yes
probe "$work/noarch" "missing --archive-body"

# 4. on-floor version but mv multi-id capability missing -> must be refused
mkdir -p "$work/nomulti"
fm_test_fake_tasks_axi "$work/nomulti" 0.2.6 yes no
probe "$work/nomulti" "missing mv multi-id"

# 5. shared fixture floor == production floor
prod=$(. "$REPO/bin/fm-tasks-axi-lib.sh" && printf '%s' "$FM_TASKS_AXI_MIN")
printf 'floor parity: fixture=%s production=%s %s\n' \
  "$FM_TEST_TASKS_AXI_VERSION" "$prod" \
  "$([ "$FM_TEST_TASKS_AXI_VERSION" = "$prod" ] && echo MATCH || echo MISMATCH)"
