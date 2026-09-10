# Environment findings during validation (pre-existing at base, not regressions)

Branch under test: fm/fm-ponytail-r1-bin-20260905
Base: f9aca259487f9d753514ecad8392fa6fca866051  Target: fe4433c41d62c9515c36fa32a014c384efdb3992

## 1. Host default locale breaks `bin/fm-test-run.sh --check-coverage` (pre-existing)

Ambient locale on this host: en_US.UTF-8.

- `bin/fm-test-run.sh --check-coverage` fails with
  `comm: file 2 is not in sorted order` at the locale-sensitive
  `comm -12 "$tmp/$a" "$tmp/$b"` (fm-test-run.sh:890) because the guard's
  temp files are sorted with `LC_ALL=C sort` but `comm` runs under the
  ambient collation.
- Verified pre-existing: the same command fails identically in a checkout of
  base commit f9aca259 (`rc=1`, same comm errors).
- Verified passing under `LC_ALL=C`:
  `FM_TEST_COVERAGE ok total=183 parallel=24 serial=146 serial_shards=5 serial_unhinted=6 herdr=13`
  and `tests/fm-test-run.test.sh` then passes all assertions
  (`FM_TEST_SUMMARY total=1 failed=0`).

## 2. Host umask 0002 rejects procevent private-directory check (pre-existing)

- With umask 0002, test-created home `state/` dirs are group-writable (775),
  so `fm-procevent.sh`'s private-directory guard correctly refuses:
  `error: process-event state root is not a private directory`
  → `not ok - could not arm the review deck` in tests/fm-captain-hold-lifecycle.test.sh.
- Verified pre-existing: identical failure at base commit checkout.
- Verified passing under `umask 022`:
  `tests/fm-captain-hold-lifecycle.test.sh exit=0` with all 32 assertions ok.

## 3. `LC_ALL=C` and the public-followup codepoint assertions are mutually exclusive on this host

- `tests/fm-public-followup.test.sh` asserts `${#text} -le 600` on a 600-codepoint
  é string. Under a single-byte locale bash counts bytes (1200), so forcing
  `LC_ALL=C` (needed by finding 1) makes that assertion fail spuriously.
- Verified the emitted event actually holds exactly 600 codepoints
  (python3 json length check on the persisted event file), and the suite
  passes under the ambient locale: `tests/fm-public-followup.test.sh exit=0`.

## Net result

Each targeted suite passes under its compatible locale/umask; the two
environment combinations cannot hold simultaneously in a single shell on this
host, so the final sweep shows one environmental failure
(`fm-test-run.test.sh`), separately verified passing under `LC_ALL=C`.
No product regression from this change range was found in either direction.
