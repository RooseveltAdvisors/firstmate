# Live lab scenario S3: a proposed divert never rewrites an explicit raw launch command (binding R-2 policy)

## spawn stdout: prober proposes pi, spawn refuses to apply it and warns
```console
fm-gate-refuse: gate agent lifecycle permitted only against lab home /tmp/fm-lab.HpF3nr
warning: jev-quota-prober proposes divert to pi:openai-codex/gpt-5.6-sol, but an explicit raw launch command is never rewritten; the quota finding was not applied
warning: /tmp/fm-lab.HpF3nr/data/raw-divert-z3/launch-brief.md records no ship branch; defaulting to legacy branch fm/raw-divert-z3
warning: /tmp/fm-lab.HpF3nr/data/raw-divert-z3/launch-brief.md records no delivery contract line (scaffolded before ship briefs recorded one); launching on the explicit --mode no-mistakes - confirm its definition of done matches
spawned raw-divert-z3 harness=custom-agent kind=ship mode=no-mistakes yolo=off window=fm-lab-spawn:fm-raw-divert-z3 worktree=/tmp/fm-lab.HpF3nr/pool/.treehouse/project-a4f91a/3/project
SPAWN_EXIT=0
```

## staged launch file: exact caller command, no harness template substituted
```sh
export COMPACT_ADVISER_DISABLE=1; export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0='/tmp/fm-lab.HpF3nr/state/raw-divert-z3.git-hooks'; custom-agent --flag
```

## task meta: raw harness identity, diverted model never leaked
```ini
window=fm-lab-spawn:fm-raw-divert-z3
endpoint_task_id=raw-divert-z3
worktree=/tmp/fm-lab.HpF3nr/pool/.treehouse/project-a4f91a/3/project
project=/tmp/fm-lab.HpF3nr/project
harness=custom-agent
kind=ship
mode=no-mistakes
yolo=off
branch=fm/raw-divert-z3
tasktmp=/tmp/fm-raw-divert-z3
model=default
effort=default
spawn_gen=s1790527372.3329067.19168
```

## argv the raw target actually received in the pane
```console
custom-agent argv: --flag
```
