# Live lab scenario S1: quota divert to pi rebuilds the Pi launch setup

## spawn stdout (real fm-spawn.sh in a real tmux lab, private socket fm-lab, marked lab home)
```console
fm-gate-refuse: gate agent lifecycle permitted only against lab home /tmp/fm-lab.HpF3nr
jev-quota-prober: automatically diverted codex:codex/gpt-5 to viable lane pi:openai-codex/gpt-5.6-sol
warning: /tmp/fm-lab.HpF3nr/data/divert-pi-z1/launch-brief.md records no ship branch; defaulting to legacy branch fm/divert-pi-z1
warning: /tmp/fm-lab.HpF3nr/data/divert-pi-z1/launch-brief.md records no delivery contract line (scaffolded before ship briefs recorded one); launching on the explicit --mode no-mistakes - confirm its definition of done matches
spawned divert-pi-z1 harness=pi kind=ship mode=no-mistakes yolo=off window=fm-lab-spawn:fm-divert-pi-z1 worktree=/tmp/fm-lab.HpF3nr/pool/.treehouse/project-a4f91a/1/project
SPAWN_EXIT=0
```

## staged launch file (what the worker pane executed)
```sh
export COMPACT_ADVISER_DISABLE=1; export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0='/tmp/fm-lab.HpF3nr/state/divert-pi-z1.git-hooks'; env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI FM_PI_HARNESS=pi '/tmp/fm-lab.HpF3nr/stubbin/pi' --tui-mode regular --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e '/tmp/fm-lab.HpF3nr/state/divert-pi-z1.pi-ext.ts' "$('/home/jon/.no-mistakes/worktrees/46339c0817e0/01M3H884K1YMR3EMJ21CPSPNKF/bin/fm-operational-input.sh' encode launch-brief < '/tmp/fm-lab.HpF3nr/data/divert-pi-z1/launch-brief.md')"
```

## task meta written by the spawn
```ini
window=fm-lab-spawn:fm-divert-pi-z1
endpoint_task_id=divert-pi-z1
worktree=/tmp/fm-lab.HpF3nr/pool/.treehouse/project-a4f91a/1/project
project=/tmp/fm-lab.HpF3nr/project
harness=pi
kind=ship
mode=no-mistakes
yolo=off
branch=fm/divert-pi-z1
tasktmp=/tmp/fm-divert-pi-z1
model=openai-codex/gpt-5.6-sol
effort=max
busy_gen=g1790527307.3047652.2910
spawn_gen=s1790527307.3037978.8777
```

## worker pane capture (treehouse worktree + staged launch sourced)
```console
treehouse get
project ➜ treehouse get
A new version of treehouse is available: v1.8.1-0.20260905115643-6e0ac79a026b →
v3.1.0
Run "treehouse update" to update

🌳 Setting up worktree...
🌳 Entered worktree at /tmp/fm-lab.HpF3nr/pool/.treehouse/project-a4f91a/1/proje
ct. Type 'exit' to return.
project ➜ export GOTMPDIR=/tmp/fm-divert-pi-z1/gotmp
project ➜ export COMPACT_ADVISER_DISABLE=1
project ➜ export BEADS_ACTOR='divert-pi-z1'
project ➜ export FM_TASK_ID=divert-pi-z1
project ➜ . '/tmp/fm-divert-pi-z1+ce88309bf89d73917f0978fc4649266f0b1f72c3f7cfdc
773b713d1c04d7cde7/launch.s1790527307.3037978.8777.sh'









```

## argv the stub pi binary actually received in the pane
```console
pi argv: --tui-mode regular --model openai-codex/gpt-5.6-sol --thinking max -e /tmp/fm-lab.HpF3nr/state/divert-pi-z1.pi-ext.ts ⁣FIRSTMATE_OP: v1 launch-brief: # Current worker role contract
```
