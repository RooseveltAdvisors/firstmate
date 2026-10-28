# fm-v0kjm live validation: a branch lease dies with its turn

Base commit `f7497919` (before the fix) compared with target commit `95ac254a`. Each live drive ran in a disposable lab home created by `bin/fm-lab-home.sh create`. The harness scripts are in `harness/`.

## 1. Incident replay on a real Pi primary (`harness/run-pi-incident.sh`)

The primary runs on the real Pi SDK 1.4.0, the same release the local `pi` CLI runs. It loads the real `fm-branch-supervision.ts` and `fm-primary-pi-watch.ts`.

What is real:

- The Pi bash tools. They run the real `bin/fm-lock.sh`, `bin/fm-lease.sh`, `bin/fm-send.sh` and `bin/fm-wake-lib.sh` (`fm_wake_append`).
- The crewmate endpoint: a pane in the lab's private tmux server.

What is scripted:

- Every model decision. A local OpenAI-compatible endpoint on 127.0.0.1 supplies them.
- The watcher arm. It is the repo's own live-probe stub, so `fm-send.sh` prints a "WATCHER DOWN" banner, because the stub writes no beacon.

### Wake 1: the shape of incident fm-g2jj0

1. The branch claims `fm-g2jj0` mid-turn.
2. The provider returns a 429, so the turn dies before the branch can release the lease.
3. The Pi process is still alive and still holds the lock.

| Step | Base (pre-fix) | Target |
|---|---|---|
| Branch lease mid-turn | `branch<TAB>pid<TAB>epoch` (no token) | `branch<TAB>pid<TAB>epoch<TAB>turn:1.1`, with `.branch-turn` = `turn=1.1` and `FM_BRANCH_REPORT_TURN=1.1` in the branch's bash |
| Main claim mid-turn | refused, rc 6, with the incident's refusal | refused, rc 6, with the incident's refusal |
| Main steer mid-turn | refused by the lease guard, rc 6 | refused by the lease guard, rc 6 |
| `fm-lease.sh check` after the turn died | `branch ... live` | `branch ... stale` |
| Main claim after the turn died | **still refused**, rc 6: `error: claim refused - task 'fm-g2jj0' is leased to the branch supervision actor (state/.lease-fm-g2jj0)` | **rc 0**, so main takes the lease |
| Main steer after the turn died | **still refused**, rc 6 | **rc 0**, and the durable inbox record `001.msg` is written and the doorbell rings |

### Wakes 2 and 3

- **Wake 2.** A normal turn claims the lease, steers, and reports, but never releases. After settlement the target reads `stale` and the session-start `sweep` removes the lease. Base keeps it `live`.
- **Wake 3.** A second Pi process that does not own the lock starts and shuts down while the owner is mid-turn. It reports `owner=false`. The owner's `turn=1.3` record survives and is removed at settlement.

Totals: target passes 26 of 26 checks and base passes its 25 base-expectation checks (`pi-live-*-observations.json`).

## 2. CLI contract, adversarial (`harness/cli-adversarial.sh`)

These checks drive the real `bin/fm-lease.sh` and `bin/fm-control.sh` against a lab home. Target passes 32 of 32. Base fails exactly the 11 turn-token checks.

Covered:

- A host-shaped turn record: while it is live, main's claim and `fm-control interrupt` are refused; once it is gone, both pass the lease guard.
- A symlinked record is ignored.
- Only an exact token match counts: `9.21`, `9`, `9.2.1` and `9.20` never match `turn=9.2`.
- A token named only on a `rows=`, `tasks=` or `wake=` line does not count.
- A malformed field 4 in the lease file falls back to the pid-only verdict.
- Forged environment tokens are never recorded.
- Main never records a token.
- A dead pid, or a pid that does not hold the lock, stays stale even when the turn record is live.
- A legacy 3-field lease keeps the old verdict byte for byte.
- `sweep` removes only the lease of the ended turn.

## 3. Supervision host with a real Claude Code 2.1.308 engine (`harness/run-host-turn.sh`)

The drive runs an away-posture wake from a real status append, through the real watcher, into one real engine turn.

- Mid-turn, the engine's lease reads `branch|<lock pid>|<epoch>|turn:host-2726193-1793205490.1`, `live`. This is the same id as `.supervision-host-turn`.
- The engine then steered, released, reported, and acknowledged the wake.
- The host ledger shows `handled ... rc=0 reports=1`, and main was never woken.
- After the turn, the lease and the turn record are both absent.

## 4. The branch's own regression tests

- `tests/fm-branch-supervision.test.sh`: 37 of 37 pass at target.
- `test_branch_wake_turn_gates_its_leases`, `test_secondary_session_stays_inert` and `test_replacement_activation_cleans_leases_and_retries_failure`: pass at target.
- Run against the base code, the two new regression tests fail: one with the incident's refusal, the other with "mid-wake branch turn record is missing".
