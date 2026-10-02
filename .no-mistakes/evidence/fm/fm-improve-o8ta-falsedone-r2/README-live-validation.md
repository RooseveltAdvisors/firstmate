# Live validation: fm/fm-improve-o8ta-falsedone-r2 (target a657b4a1, base 8690c411)

Intent under test:
1. **Skip identical config-reread payloads** - the reread sender must compare
   against the home's latest delivered payload and send no pointer for a
   byte-identical payload; `config-reread: sent` must report an actual send
   (including an older-pending drain).
2. **Require a PR before ship done** - the generated ship definition of done
   treats a commit as validation input only and requires a pushed branch with an
   open PR with checks green (or attestation green) before done; a bare no-mistakes
   `done:` is never reported as terminal done.

## Method

Every scenario below drives the REAL firstmate entry points (`bin/fm-config-push.sh`,
`bin/fm-config-inherit-lib.sh`'s `fm_config_send_reread_nudge`, `bin/fm-crew-state.sh`,
`bin/fm-inactive-reconcile.sh`, `bin/fm-brief.sh`, `bin/fm-send.sh`) in disposable
fixtures: a marked lab home (`bin/fm-lab-home.sh create`), a throwaway secondmate
home, and a real tmux server on a private socket whose panes run a `codex`-named
agent shell. No fake tmux, no fake crew-state: the only faked tools are the forge
CLIs (`gh`, `gh-axi`, `glab`, `gerrit-axi`, `curl`), which log-and-refuse so the
fixtures also prove no forge claim is made from the fixtures themselves.
All worlds are created under `mktemp -d` and removed by the drivers' exit traps.

Fail-before: the same driver sequences run against the base commit's scripts,
extracted with `mkdir -p <dir>/base-bin && git archive 8690c411 bin | tar -x -C <dir>/base-bin`
and passed as the bin dir (or `BASE_BIN=` for the ship-done contrast).

## Scenarios and results (target)

| # | Scenario | Result |
|---|----------|--------|
| A | First changed config push sends exactly one `CONFIG_REREAD` pointer, prints `config-reread: sent`, and the live agent's terminal receives the wake (`Firstmate instruction waiting...`) | PASS |
| B | Unchanged config push prints no `config-reread: sent` and adds no pointer | PASS |
| C/C2 | Destination copy lost or drifted so the propagate report says `pushed` while the payload is byte-identical to the delivered generation: no new generation, no pointer, no label (base: re-sends every time - 13 fail-before failures) | PASS |
| D/E/F | Real send failure keeps the generation `.pending` with its retained stage (rc 1, diagnostic); a bootstrap-respawn-shaped run (`FM_CONFIG_REREAD_SKIP_PENDING=1`) delivers only the newer generation; the later normal run drains the OLDER pending generation and still prints `config-reread: sent` | PASS |
| G/G2 | One delivery carrying two byte-identical sibling stages sends exactly one pointer; two differing siblings both send (base: both identical siblings sent) | PASS |
| crew-state 1 | Bare no-mistakes `done: implementation complete` reads `state: blocked` with the claim visible and the reason "reports no validated no-mistakes delivery" (base: `state: done`) | PASS |
| crew-state 2 | `done: PR <url> checks green` with the head pushed reads `state: done` (positive control) | PASS |
| crew-state 3 | Same CI-ready claim with an unpushed HEAD reads `state: blocked` - "unreachable outside the worker copy" (guard intact) | PASS |
| crew-state 4 | Bare summary even with recorded `pr=` + `pr_head=` on the forge still reads `state: blocked` (adversarial bypass) | PASS |
| reconcile | Ledger scan publishes the CI-ready child upstream, never publishes the bare-summary child (base: publishes `child bare done:`), and the same child becomes deliverable once its claim turns CI-ready | PASS |
| brief contract | Generated `Definition of done` for no-mistakes (pushed branch + open PR + checks/attestation green, commit is validation input only, no handoff `done:`), gerrit no-mistakes (run outcome + published change), direct-PR (pushed + open PR), direct-PR gerrit (pushed + open change); base brief orders `done: {summary}` from the bare commit | PASS |

## Files

- `live-config-push.sh` - driver for scenarios A-G (target and base).
- `live-config-push.target.log` / `live-config-push.target.out` - target transcript (`[target] ALL PASS`).
- `live-config-push.base.log` / `live-config-push.base.out` - base fail-before transcript (13 failures, re-sent byte-identical payloads).
- `live-ship-done.sh` - driver for the crew-state / reconcile / brief scenarios.
- `live-ship-done.target.log` / `live-ship-done.target.out` - target transcript including the base contrasts (`[target] ALL PASS`).

Supporting (not live, cited in `tested`): the eight changed test files all pass:
`tests/fm-secondmate-harness.test.sh`, `tests/fm-crew-state.test.sh`,
`tests/fm-dod-lib.test.sh`, `tests/fm-brief.test.sh`, `tests/fm-inactive-reconcile.test.sh`,
`tests/fm-bearings-snapshot.test.sh`, `tests/fm-fleet-snapshot-view.test.sh`,
`tests/fm-task-delivery.test.sh`.
