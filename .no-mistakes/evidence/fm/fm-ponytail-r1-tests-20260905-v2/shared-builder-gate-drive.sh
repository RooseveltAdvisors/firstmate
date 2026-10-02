#!/usr/bin/env bash
# Adversarial product-level drive: the shared tests/fixtures.sh fake-CLI
# builders must satisfy the REAL product compatibility gates in bin/, and those
# gates must still reject degraded/absent CLIs.
set -u
ROOT=$(pwd)
. "$ROOT/tests/fixtures.sh"
. "$ROOT/bin/fm-tasks-axi-lib.sh"
. "$ROOT/bin/fm-quota-axi-lib.sh"

D=$(mktemp -d "${TMPDIR:-/tmp}/fm-gate-drive.XXXXXX")
trap 'rm -rf "$D"' EXIT
pass=0; fail=0
check() { # <label> <expected-rc> <actual-rc>
  if [ "$2" = "$3" ]; then
    printf 'PASS: %s (rc=%s)\n' "$1" "$3"; pass=$((pass+1))
  else
    printf 'FAIL: %s (expected rc=%s got rc=%s)\n' "$1" "$2" "$3"; fail=$((fail+1))
  fi
}

# --- tasks-axi gate -------------------------------------------------------
FB=$D/tasks-ok; mkdir -p "$FB"
fm_test_fake_tasks_axi "$FB"
PATH="$FB:/usr/bin:/bin:/usr/sbin:/sbin" bash -c ". '$ROOT/bin/fm-tasks-axi-lib.sh'; unset FM_TASKS_AXI_COMPATIBLE_MEMO; fm_tasks_axi_compatible"
check "shared fm_test_fake_tasks_axi (default 0.2.6) passes fm_tasks_axi_compatible" 0 $?

FB=$D/tasks-old; mkdir -p "$FB"
fm_test_fake_tasks_axi "$FB" 0.2.5
PATH="$FB:/usr/bin:/bin:/usr/sbin:/sbin" bash -c ". '$ROOT/bin/fm-tasks-axi-lib.sh'; unset FM_TASKS_AXI_COMPATIBLE_MEMO; fm_tasks_axi_compatible"
check "tasks-axi below FM_TASKS_AXI_MIN (0.2.5) is refused by fm_tasks_axi_compatible" 1 $?

FB=$D/tasks-noarchive; mkdir -p "$FB"
fm_test_fake_tasks_axi "$FB" 0.2.6 no
PATH="$FB:/usr/bin:/bin:/usr/sbin:/sbin" bash -c ". '$ROOT/bin/fm-tasks-axi-lib.sh'; unset FM_TASKS_AXI_COMPATIBLE_MEMO; fm_tasks_axi_compatible"
check "tasks-axi without --archive-body capability is refused" 1 $?

FB=$D/tasks-nomulti; mkdir -p "$FB"
fm_test_fake_tasks_axi "$FB" 0.2.6 yes no
PATH="$FB:/usr/bin:/bin:/usr/sbin:/sbin" bash -c ". '$ROOT/bin/fm-tasks-axi-lib.sh'; unset FM_TASKS_AXI_COMPATIBLE_MEMO; fm_tasks_axi_compatible"
check "tasks-axi without multi-id mv usage is refused" 1 $?

FB=$D/tasks-none; mkdir -p "$FB"
PATH="$FB:/usr/bin:/bin:/usr/sbin:/sbin" bash -c ". '$ROOT/bin/fm-tasks-axi-lib.sh'; unset FM_TASKS_AXI_COMPATIBLE_MEMO; fm_tasks_axi_compatible"
check "absent tasks-axi is refused" 1 $?

# --- quota-axi gate -------------------------------------------------------
FB=$D/quota-ok; mkdir -p "$FB"
fm_test_fake_quota_axi "$FB"
PATH="$FB:/usr/bin:/bin:/usr/sbin:/sbin" bash -c ". '$ROOT/bin/fm-quota-axi-lib.sh'; fm_quota_axi_compatible"
check "shared fm_test_fake_quota_axi (default 0.1.51) passes fm_quota_axi_compatible" 0 $?

FB=$D/quota-old; mkdir -p "$FB"
fm_test_fake_quota_axi "$FB"
PATH="$FB:/usr/bin:/bin:/usr/sbin:/sbin" FM_FAKE_QUOTA_AXI_VERSION=0.1.50 bash -c ". '$ROOT/bin/fm-quota-axi-lib.sh'; fm_quota_axi_compatible"
check "quota-axi below FM_QUOTA_AXI_MIN (0.1.50) is refused" 1 $?

FB=$D/quota-none; mkdir -p "$FB"
PATH="$FB:/usr/bin:/bin:/usr/sbin:/sbin" bash -c ". '$ROOT/bin/fm-quota-axi-lib.sh'; fm_quota_axi_compatible"
check "absent quota-axi is refused" 1 $?

printf 'TOTAL pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
