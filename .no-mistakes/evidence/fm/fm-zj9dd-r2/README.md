# CI-wait behavioral verification

Tests execute the real watcher, wake queue/drain, and crew-state CLI with hermetic tmux and no-mistakes responses. No live fleet or GitHub checks were contacted. Original private lane status/history was unavailable in this worktree.

`run-focused.sh` invokes four selected existing watcher tests and saves actual supervisor-facing output in `watcher-transcript.txt`.

`ci-state-focused.sh` contains the existing crew-state test definitions (up to their invocation block) and four selected CI tests, followed by two CLI output captures. To replay it, temporarily place it in this checkout's `tests/` directory so its relative helper imports resolve, run with Bash, then remove the temporary copy.

The existing `run_ci_monitoring` fixture has top-level `status: running` and a step row `ci,running,0,0`, with logs `CI checks running, waiting for results...`. The actual classifier emits `validating (running)` (crew-state-transcript.txt). Changing only the run fixture to top-level `status: ci` emits `ci running` (crew-state-top-level-ci.txt).

`reproduce-ci-step.sh` passes that actual classifier output into the watcher fixture. Its assertion fails: the watcher emits `possible wedge, escalation 1` (actual-ci-step-wake.txt). This exposes the gap masked by the new watcher tests' canned `ci running` verdict.
