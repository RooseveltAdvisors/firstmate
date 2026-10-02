# Live validation — fm/herdr-server-scrub-nocolor (target 83505fa)

Change under test: shared color-control scrub (`bin/fm-backend-launch-env-lib.sh`,
`unset NO_COLOR FORCE_COLOR CLICOLOR CLICOLOR_FORCE`) applied by the tmux, Herdr,
and zellij adapters in the subshell that births a long-lived server, plus the two
review fixes (tmux reuse probe no longer vacuous; color assertions line-anchored).

All scenarios were driven against the real product in this run. Herdr work used
named non-default `fm-lab-*` sessions through `bin/fm-herdr-lab.sh`
(prepare/provision/teardown + default-session tripwire); both labs were torn down
in the same turn. tmux work used real tmux servers on private `-L` sockets. zellij
0.44.0 (sha256-verified release binary) ran with isolated `XDG_*` dirs and a
private runtime dir, all scratch removed afterwards.

## Scenarios and evidence

1. **tmux: birth scrub vs. unscrubbed control** — `tests/fm-backend-tmux-smoke.test.sh`
   births a control tmux server under `NO_COLOR=1 FORCE_COLOR=0 CLICOLOR=0
   CLICOLOR_FORCE=1` (leak proven: the later window receives `NO_COLOR=1`), then
   births through `fm_backend_tmux_container_ensure` (all four absent from a later
   window, `FM_TMUX_LAUNCH_SENTINEL=kept` intact). → `tmux-smoke-run.txt` (exit 0).
2. **tmux: reuse keeps the same server and a clean environment** — second
   `container_ensure` call: same server pid, no restart, windows born afterwards
   carry no color vars. → `tmux-smoke-run.txt`.
3. **Herdr: lab server birthed by firstmate hands panes no color control** —
   control session `fm-lab-ctl-…` provisioned unscrubbed under pollution: pane env
   contains `NO_COLOR=1 FORCE_COLOR=0 CLICOLOR=0 CLICOLOR_FORCE=1
   FM_SCRUB_SENTINEL=kept` → `herdr-color-scrub/control-pane-env.txt`.
   Fixed session `fm-lab-fix-…` birthed via
   `fm_backend_herdr_container_ensure` (→ `fm_backend_herdr_server_ensure`) under
   the same pollution: pane env has **none** of the four and keeps the sentinel →
   `herdr-color-scrub/fixed-pane-env.txt`. Both labs torn down →
   `herdr-color-scrub/teardown.txt`.
4. **Herdr: reuse does not restart the server; later panes stay clean** — second
   `container_ensure` under pollution returned the same workspace and the server
   pid was identical before/after (`1270815` → `1270815`); a workspace created
   after the reuse call has a pane with no color vars and the sentinel intact →
   `herdr-color-scrub/fixed-pane-env-after-reuse.txt`.
5. **zellij: server_ensure births a session without color control** — control
   session birthed by a raw `zellij attach -b` under pollution: both the zellij
   server process and its pane shell carry all four vars.
   Fixed session birthed by `fm_backend_zellij_server_ensure`: server and pane
   shell carry none of the four, sentinel kept → `zellij-color-scrub-live.txt`.
6. **Test-quality fix 1 (vacuous reuse probe)** — the same injected failure
   (`reused_env=$(false)`) was run against both copies of the tmux smoke test:
   pre-fix version (f37bc84b) exits **0** printing `ok - the reuse path leaves the
   scrubbed server environment clean…` (wrong pass); fixed version (83505fa)
   exits **1** with `not ok - the reuse path's environment probe … failed` →
   `probe-mutation-experiment.txt`.
7. **Test-quality fix 2 (line-anchored color assertions)** — `assert_line`
   driven directly on `tests/lib.sh`: each of `NO_COLOR/FORCE_COLOR/CLICOLOR/
   CLICOLOR_FORCE` independently fails when only that key leaks and passes on a
   clean haystack → `assert-line-behavior.txt`. That file also records that the
   recorded finding's substring premise (`FORCE_COLOR=<unset>` inside
   `CLICOLOR_FORCE=<unset>`) does not reproduce: `grep -F` shows the needle is not
   a substring and the old `assert_contains` already fails on the drift haystack.

## Suites run (all green, exit 0)

- `bash tests/fm-backend-tmux-smoke.test.sh` → `tmux-smoke-run.txt`
- `bash tests/fm-backend-herdr.test.sh` (227 ok, 0 not ok) → `fm-backend-herdr-run.txt`
- `bash tests/fm-backend-zellij.test.sh` (65 ok) → `fm-backend-zellij-run.txt`
- `bash tests/fm-gotmp.test.sh` → `fm-gotmp-run.txt`

## Cleanup verified

Lab sessions deleted and tripwires removed, no `fm-lab-ctl/fix` processes, no
private tmux servers left by the smoke test, no zellij processes/sessions (the
downloaded binary, isolated XDG dirs, and the stray runtime socket removed), user
`~/.config/zellij` untouched, worktree `git status` clean.
