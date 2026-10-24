# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Balance hints come from serial runs of the real lanes on `ubuntu-latest`.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not serial CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

### Current refresh (2026-10-16)

Both hint tables retain their previous measured maxima and include successful per-script samples from house CI runs [36703559612](https://github.com/RooseveltAdvisors/firstmate/actions/runs/36703559612), [38627719655](https://github.com/RooseveltAdvisors/firstmate/actions/runs/38627719655), and [38926999034](https://github.com/RooseveltAdvisors/firstmate/actions/runs/38926999034).
The middle run is completely green; completed successful scripts from the partial runs supplement it.
Failed scripts are excluded, and missing or unfinished scripts are never assigned a duration from a job's timeout.
The artifacts cover all 24 parallel and 519 serial members after the splits below.
An existing live-capability skip measures the portable runner, not the unavailable live integration.
Observed maxima are conservative packing weights, not upper bounds on future duration.

Two indivisible suites exceeded the twenty-minute packing target in the latest successful script samples: supervision-host took 1497756 ms and watch-triage took 1223771 ms.
They now share their existing fixture and case definitions between two executable entries each, preserving all 75 host cases and 149 watcher cases.
The host split is after `test_report_without_acknowledgement_hands_the_wake_to_main` (57 core cases, 18 recovery cases).
The watcher split is after `test_wedge_threshold_defers_to_a_declared_wait_under_a_working_verdict` (94 core cases, 55 wait cases).
Both entries retain `FM_TEST_ONLY`, including the stock macOS Bash regression's original entry point.

The split hints use the green and partial runs' completed log timestamps at those exact case boundaries, cross-checked against their successful `FM_TEST_END` duration markers.
For each sample, the first segment runs from `FM_TEST_BEGIN` to the boundary's `ok -` line, and the second from that line to `FM_TEST_END`.
Add the original trailing cleanup interval to the first segment and the original first-case interval to the second, conservatively covering repeated setup and cleanup.
Round each interval up to milliseconds and retain the larger segment sample across both runs.
This gives host hints of 768458 ms and 744724 ms, and watcher hints of 625799 ms and 598874 ms.
These are CI-derived segment estimates, and whole-entry timing artifacts will refresh them once CI has exercised the split.

Ten serial runners fit the refreshed model without raising any timeout.
Parallel membership is repacked by longest-processing-time assignment, retaining the Pi typecheck prerequisite on shard 1.
The executable verification command is `bin/fm-test-run.sh --check-coverage`.

### Retained baseline

The 2026-09-30 upstream baseline used successful artifacts and completed log markers from runs [36583881812](https://github.com/kunchenguid/firstmate/actions/runs/36583881812), [36658498535](https://github.com/kunchenguid/firstmate/actions/runs/36658498535), [36663947738](https://github.com/kunchenguid/firstmate/actions/runs/36663947738), [36664663190](https://github.com/kunchenguid/firstmate/actions/runs/36664663190), and [36669175457](https://github.com/kunchenguid/firstmate/actions/runs/36669175457).
The house baseline added successful artifacts from runs 36703559612, 36627768210, 36627563662, 36416232300, 36388227376, 36348237890, 36340830763, and 36331959069, taking the larger of each measurement and its existing documented hint.
The retained house hints also include the 25 previously unhinted or newly added serial scripts measured in runs [38930940577](https://github.com/RooseveltAdvisors/firstmate/actions/runs/38930940577) and [38938137822](https://github.com/RooseveltAdvisors/firstmate/actions/runs/38938137822), taking the larger measurement except for the documented split-suite estimates.
The consequential action gate hints for `tests/fm-action-adapter.test.sh` and the regrown `tests/fm-action-gate.test.sh` take the slowest successful serial sample from runs [39916933506](https://github.com/RooseveltAdvisors/firstmate/actions/runs/39916933506) and [39920173201](https://github.com/RooseveltAdvisors/firstmate/actions/runs/39920173201).
The native-Windows-only `tests/fm-pi-windows-shell-invocation.test.sh` retains its separate 5121 ms measurement from 2026-09-06T21:02Z rather than a portable capability skip.
The 2026-10-07 polytoken adapter tests carry provisional local measurements instead: 21090 ms for `tests/fm-polytoken-harness.test.sh` and the 103 ms live-guard skip for `tests/fm-polytoken-signals-live-e2e.test.sh`, both measured on the adapter-verification macOS host, until the next CI refresh replaces them with Ubuntu measurements, because they postdate the 2026-09-30 baseline.
The 2026-10-23 `tests/fm-approval-failover.test.sh` serial hint is a provisional local measurement of 5410 ms, the slowest of five local `bin/fm-test-run.sh` samples (4991 to 5410 ms), until the next CI refresh replaces it with an Ubuntu timing-artifact maximum.
The 2026-10-23 Kimi folder-prompt live guard, `tests/fm-kimi-trust-prompt-live-e2e.test.sh`, carries a provisional 60 ms skip measured on the Linux host that recorded its captures, until the next CI refresh replaces it with an Ubuntu measurement.
The wedge-cap suite carries the Ubuntu measurements from CI run [39597689178](https://github.com/kunchenguid/firstmate/actions/runs/39597689178): 374225 ms for `tests/fm-watch-wedge-cap.test.sh` and the 74 ms live-guard skip for `tests/fm-watch-wedge-cap-live.test.sh`, in place of the provisional local measurements the suite first carried (1003000 ms and the 155 ms skip), which overstated the CI cost of both.
They are not a formality: without a hint the suite is packed on the 45000 ms default, which puts it beside a shard already holding about 17 minutes of measured work, so that shard would really have run for about 23 minutes, past the 20-minute target the guard reserves, while the coverage guard still passed.
The same run measured the wedge-cap parity suite at 27763 ms, which `bin/fm-test-run.sh` packs in place of the provisional 209000 ms local measurement.
`test_portable_serial_packing_budget_boundary` now pins every other fixture script to 1 ms, so packing exactly at the 1200000 ms budget is accepted and one millisecond above it is refused even when real serial members have no hint.
The coverage-guard test owns modeled real-hint headroom under that budget.
The session-start hint retains its pre-optimization maximum until CI measures the shorter fixture-only home-summary bound, and local speedups do not discount CI packing weights.

## Parallel lanes

The two parallel lanes use longest-processing-time assignment over those hints.
[`tests/fm-pi-primary-types.test.sh`](../tests/fm-pi-primary-types.test.sh) owns its typecheck dependencies independently of the lane's installed Pi runtime.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) holds the duration values in `portable_parallel_weight_hints` and the ordered memberships and lane-specific prerequisite constraints beside `list_portable_parallel_1` and `list_portable_parallel_2`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The CI cap follows the three-tier timeout policy in [Timeouts](#timeouts) below.

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the lane sums to differ by no more than five percent of the larger sum.
Its scheduling regressions also check stored parallel lane order and preserve serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `portable_parallel_weight_hints` with the slowest completed `duration_ms` per script from several green CI runs' `fm-test-timing-portable-parallel-*` artifacts whenever the parallel set gains scripts or a member grows materially.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
[Verification inputs](#verification-inputs) owns the measurement provenance and exceptions.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
`bin/fm-test-run.sh --check-coverage` reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`.
That catches missing hints, not stale existing hints: the host suite still had a 41512 ms hint after growing to over 1000 seconds in CI, so the old split placed it beside another 12 minutes of work while passing the guard.
Refresh the hints whenever a serial member grows materially or the lane gains scripts, rather than waiting for missing-hint coverage to trip.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size and coverage rather than a copied inventory.
Its header and `--help` own the modeled-budget check and output fields; read the current estimates from `--check-coverage` instead of retaining copied lane sums here.
[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_serial_packing_budget_boundary`, verifies acceptance exactly at the budget and refusal one millisecond above it through the executable runner.
The largest individual script hint remains the indivisible floor for any layout; the current host and watcher splits are described in [Verification inputs](#verification-inputs).
The estimates use per-file maxima from different runs, not measured rebalanced jobs or an end-to-end latency guarantee.
Per-script maxima and segment estimates do not establish a P95 or guarantee future headroom.
Job timeouts remain hang tripwires under the policy in [Timeouts](#timeouts) below; they are not the desired healthy duration.
`tests/fm-ci-workflow.test.sh` compares the parsed CI matrix to the executable runner lanes, and the runner rejects parallel `--jobs` on a serial lane even when that shard has only one member.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs and replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh-axi run download "$run" -R kunchenguid/firstmate --dir "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | select(.exit == 0) | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/fm-test-timing-portable-serial-*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard may upload no artifact, so include a complete green run or the slowest scripts go unmeasured in exactly the shard that needs them most.
Completed shards from a partial run can supplement that complete baseline, but never treat missing tail scripts or the timeout duration as successful samples.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
Its hint-coverage and modeled-budget checks are described in [Portable serial CI shards](#portable-serial-ci-shards); neither replaces inspection of actual CI timing artifacts.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Lint partitions and end-to-end latency

`bin/fm-lint.sh` owns two canonical CI partitions, each attempting full source-aware ShellCheck analysis and running workflow validation and backend-purity checks.
CI requires its per-root bounds, so an unenforceable deadline or address-space limit refuses lint rather than running uncapped; the script header owns the envelope, per-root execution contract, and memory fallback.
Its `--list-files` interface exposes partition membership; `tests/fm-lint.test.sh` verifies complete/disjoint executed roots, initial analysis flags, and fallback reporting.
The workflow uploads each partition's quiet telemetry plus its per-root lifecycle sidecar to distinguish analysis cost, memory use, and host contention.
No fast mode, path skips, or paid runner provisioning is part of this layout.

The longer-term performance objective remains a complete green run under fifteen minutes including start delay, but the current modeled serial packing still exceeds that objective.
The immediate packing target is the runner's modeled script budget, not a claim that more shards alone can make an indivisible script faster.
The layout uses fifteen long-lived Linux jobs (ten serial, two parallel, Herdr, two lint), plus short checks and macOS; insufficient shared account capacity can erase the packing gain.
Compare complete before/after runs, preserve cancelled and partial-run evidence, and measure a representative normal-run sample before claiming a P95 improvement.
The workflow retains per-PR supersession without cancelling main pushes or changing the compliance workflow's event semantics.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

CI job timeouts follow one three-tier policy, so the workflow reads as a policy rather than as a collection of per-job numbers.
Every tier is a hang tripwire with headroom above the healthy duration, never a packing estimate or a runtime target.
A lane that reaches its tier bound needs investigation and a distribution or runtime fix, not a larger timeout to fit the same work.

| Tier | Jobs | Bound | Rationale |
|---|---|---|---|
| Fast | coverage guard, repo invariants, timing aggregate | 5 minutes | Seconds-long local work, so the tripwire only catches a hung runner. |
| Normal | lint partitions, portable parallel shards, portable serial shards, macOS stock Bash | 30 minutes, one value shared by every job in the tier | One shared hang tripwire keeps every ordinary test and lint lane on the same policy instead of allowing per-lane packing estimates or one-off caps to set the bound. |
| Heavy | Herdr | family-run step 20 minutes under a 75-minute job-level last-resort backstop | Healthy runs finish in about 7-10 minutes, so the step tripwire fails a wedged suite while the `always()` cleanup and timing upload still run, and the job cap only catches a hang outside that step. |

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) holds the executable values and names each job's tier beside its `timeout-minutes`.
[`tests/fm-ci-workflow.test.sh`](../tests/fm-ci-workflow.test.sh) holds the policy against the parsed workflow: every job belongs to exactly one tier, the workflow carries exactly three distinct job-level values, the fast tier stays within 5-10 minutes, the normal jobs share one 30-minute budget, and the Herdr family-run step is the 20-minute tripwire below its job backstop with an `always()` teardown after it.
A passing coverage guard does not establish a healthy job duration; refresh the healthy figures above from the lanes' uploaded timing artifacts.
