# Declared mechanical verification of a ship `done:`

Audience: maintainer verification.

This record supports the declared-verification half of the ship `done:` gate owned by [`../../bin/fm-dod-lib.sh`](../../bin/fm-dod-lib.sh), whose header owns the `state/<id>.verify` format, and summarized in [`../architecture.md`](../architecture.md).
It records the empirical demonstration that one mechanical check refuses a bad `done:` and accepts a good one, because that is the only claim the pilot makes.
It records nothing about coverage the pilot does not exercise.

## What the structural gate cannot see

The named-head reachability gate proves a commit left the worker's disposable copy.
It cannot prove the change works.
A worker can push a correct-looking diff, satisfy every reachability test, and report `done:` while the URL the change claims to have fixed is dead.
An independent reviewer reading that diff sees a correct-looking diff, so review does not close this gap either; the declared check does, by fetching the URL and reporting the status it actually got.
Declared verification therefore complements independent review rather than replacing it, and upstream firstmate PR #1470 (closed stale 2026-08-25) remains the separate, reviewer-side proposal.

## The demonstration

Run 2026-09-27 on Linux 6.17.0-35-generic against upstream firstmate `3b689975`, with GNU bash 5.2.21, curl 8.19.0, and Python 3.14.7.

One task, one `done:` line, one declared check, two outcomes.
The task is put in the shape the structural gate already accepts: a real git worktree whose named head is reachable from `refs/remotes/origin/fm/declared`, `kind=ship`, `mode=no-mistakes`, and the status log's only line is `done: PR https://example.test/o/r/pull/9 checks green`.
Its declaration is a single line in `state/declared.verify` at mode 600:

```
http: http://127.0.0.1:<port>/ 200 the live fix is deployed
```

The orchestrator's own current-state read decides it.
With the local site up and serving that text, `bin/fm-crew-state.sh declared` printed:

```
state: done · source: status-log · PR https://example.test/o/r/pull/9 checks green
```

The site was then stopped and nothing else changed - same task, same commit, same `done:` line, same declaration.
The same command printed:

```
state: blocked · source: status-log · declared verification failed: http: http://127.0.0.1:43333/ could not be fetched
```

The worker that reported `done:` evaluates neither read.

## Refreshing this record

```
bash tests/fm-crew-state.test.sh     # test_declared_verification_decides_a_pushed_ship_done
bash tests/fm-dod-lib.test.sh        # the six declared-verification cases
```

Both ran green on the date above.
`tests/fm-crew-state.test.sh` drives the demonstration above end to end through `bin/fm-crew-state.sh` over a real throwaway git repo and a real local HTTP server, with no harness and no model.
`tests/fm-dod-lib.test.sh` covers the library directly: the live/dead pair, a reachable site serving the wrong content and the wrong status, `run:` and `file:` in both directions, an absent declaration gating nothing, a declaration that is not a firstmate-private file, and a malformed or unknown check.

## Mutation evidence

The checks are load-bearing rather than decorative: on 2026-09-27 three independent mutations of `bin/fm-dod-lib.sh` were each caught by `tests/fm-dod-lib.test.sh`.

| Mutation | Test that failed |
| --- | --- |
| The gate call removed from `fm_dod_accept_ship_done` | `a done: whose declared live check cannot reach the site was accepted (exit 0)` |
| An unknown check verb skipped instead of refused | `an unknown declared check was accepted (exit 0)` |
| The private-file validation of the declaration bypassed | `a world-readable declaration was trusted (exit 0)` |

## What the pilot does not establish

A declaration is optional, and an absent one gates nothing, so this pilot says nothing about tasks that declare no checks.
No mechanism decides which tasks should declare which checks; that is firstmate's judgment at dispatch.
The pilot exercises `http:` end to end through the orchestrator and `run:` and `file:` at the library, over a local server only; it establishes nothing about a remote host, TLS, redirects beyond curl's own `-L`, or authenticated fetches.
A target ends at the first space, so a path or URL containing one is outside `file:` and `http:` and needs `run:`; nothing in the pilot exercises that case.
The only fail-open path is a declaration that was never written, which firstmate knows because firstmate writes it; a declaration present but untrusted or malformed refuses the claim.
