# Live validation: weekly instruction review fired from a due-dated bead

Product driven: `bin/fm-explained-twice.sh weekly --work-dir DIR --sources FILE` (public CLI) against a
**real `bd` 1.3.1 embedded-Dolt store** created with `bd init --sandbox` in a throwaway temp dir (`/tmp/fm-weekly-live.*`,
removed after the run). No fake `bd`, no real fleet store, no production bead touched. Raw outputs are in `raw/`.

## Cycle 1 (first run, no prior stamp) — `raw/cycle1.out`, `raw/cycle1-weekly-run.json`, `raw/cycle1-corpus.json`
- Driver bead `fm-zon` created with due 2026-10-01 and `metadata.unrelated=preserved`. Plain `bd ready` had already rolled the
  overdue due_at to now+1d (`2026-10-25T13:50:25Z`) — the exact behaviour the code comment warns about; due-ness comes from the stamp.
- Run at `ran_at=2026-10-24T13:50:25.000Z` → window `[2026-10-17T13:50:25Z, 2026-10-24T13:50:25Z)`; `closed_beads: 1` (fixture closed at 13:50:08).
- Bead after: `due_at=2026-10-31T13:50:25Z` (exactly +7d at whole-second precision), `metadata.weekly_review` stored as an **object**
  with artifact path + sha256, `unrelated` preserved. `bd ready` now lists the bead with the new due date (self-rescheduled).
- strace of the whole cycle (`raw/cycle1-strace-execve-summary.txt`): only `bash`, `bd`, `bun`, `dirname`, `git` executed
  (`env` is the test wrapper). Zero opens of systemd/cron/init.d/launchd/at paths (`raw/cycle1-strace-scheduler-opens.txt`). No timer units.

## Idempotent re-invocation before due — `raw/A-same.out`, `raw/A-other.out`
- Same work-dir and a different work-dir both print `already_complete:true`; bead revision unchanged; other work-dir stays empty.

## Stale work-dir replay refused — `raw/B.out`
- Bead made due (next_due_at = ran_at via real `bd update --metadata`), rerun with cycle-1 work-dir → exit 1,
  `weekly artifact window does not continue the stamped cycle ... use a new --work-dir`; bead unchanged.

## Cycle 2 tiles and reclaims a dead lock AND dead .takeover guard — `raw/C.out`, `raw/cycle2-*.json`
- Lock + `.takeover` pre-seeded with a confirmed-exited pid → both logged `taking over stale weekly lock from exited pid`, both removed.
- Window `[2026-10-24T13:50:25Z, 2026-10-24T13:51:54Z)`: since == cycle-1 ran_at exactly; due re-dated to ran_at+7d.
- Empty window reported explicitly: `closed_beads: 0`, corpus note `0 closed records ... returned for [since, until)`.
  (The bead closed between cycles was stored by Dolt as 13:51:55, one second after this run's captured 13:51:54 — see cycle 3.)

## Real SIGKILL mid-cycle, then cycle 3 takes over — `raw/K.out` (empty: killed before output), `raw/cycle3.out`, `raw/cycle3-*.json`
- A real cycle was started and SIGKILLed (exit 137) the instant its pid appeared in the lock; lock left behind with that pid; bead not updated.
- Cycle 3: `taking over stale weekly lock from exited pid 922465`, window `[13:51:54Z, 13:54:17Z)` starts exactly at cycle 2's ran_at,
  `closed_beads: 1` = the bead closed at 13:51:55 that fell just past cycle 2 → **no gap, each close lands in exactly one cycle**. Lock removed.

## Refusals that never re-date — `raw/R1..R5.out`
- R1 unknown driver id → `weekly bead refused ... Issue fm-nope not found` (verbatim bd stderr).
- R2 databasePath of a second real store → `weekly driver store identity mismatch`.
- R3 `--week` with a driver → `omit --week`. R4 closed driver bead → `weekly driver is not open`. R5 missing store dir → ENOENT named.
- Bead revision identical before/after; work-dirs left empty.

## Lock shapes while the bead is DUE (a wrong pass would have re-dated it) — `raw/X1..X5.out`
- X1 live pid → `locked by running pid N: <lock>; remove it only if no weekly run is active`, lock intact.
- X2 `not-a-pid` → `locked by an unreadable pid`, lock intact (never reclaimed).
- X3 dead lock + claim held by live pid → refuses naming the `.claim.<inode>` file; lock and claim intact.
- X4 dangling symlink at the lock path (name exists at link time, gone at owner read) → `weekly driver lock changed during takeover`, no raw ENOENT.
- X5 dead lock + dangling `.takeover` symlink → same named refusal on the guard. Bead still due and unchanged after all five.

## Three simultaneous cycles over a dead lock — `raw/race-1..3.out`
- Exactly one racer took over and completed (`already_complete:false`); the other two refused with `locked by running pid <winner>`.
  One `weekly-run.json` exists; one bead update; no lock/claim/takeover files left in tmpdir.

## Legacy serialized stamp — `raw/L1.out`, `raw/L2.out`
- Stamp written as a JSON **string** via real `bd --set-metadata`; pre-due run verified the artifact and rewrote the stamp as an object
  (`already_complete:false`, due unchanged, no new corpus); the next run is `already_complete:true`.

## Existing suites — `raw/suite-explained-twice.log`, `raw/suite-rule-conformance.log`
- `tests/fm-explained-twice.test.sh` (runs `bun test tests/fm-weekly-bead.test.ts`: 30 pass, then the fake-bd shell suite): exit 0.
- `tests/fm-rule-conformance.test.sh`: exit 0.

Final state: `raw/final-bead-fm-zon.json`, `raw/final-bd-ready.json`, `raw/closed-beads.json`. Lab dir removed afterwards.
