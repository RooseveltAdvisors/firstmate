# Live lab scenario S2: real quota prober diverts a doomed pi lane to Cursor and rebuilds the Cursor launch setup

## spawn stdout (NO test seam: production bin/fm-jev-quota-prober.sh did the probe and divert)
```console
fm-gate-refuse: gate agent lifecycle permitted only against lab home /tmp/fm-lab.HpF3nr
jev-quota-prober: automatically diverted pi:zai-general/glm-5.3-flash to viable lane cursor:cursor-grok-4.6-high
warning: /tmp/fm-lab.HpF3nr/data/divert-cursor-z2/launch-brief.md records no ship branch; defaulting to legacy branch fm/divert-cursor-z2
warning: /tmp/fm-lab.HpF3nr/data/divert-cursor-z2/launch-brief.md records no delivery contract line (scaffolded before ship briefs recorded one); launching on the explicit --mode no-mistakes - confirm its definition of done matches
spawned divert-cursor-z2 harness=cursor kind=ship mode=no-mistakes yolo=off window=fm-lab-spawn:fm-divert-cursor-z2 worktree=/tmp/fm-lab.HpF3nr/pool/.treehouse/project-a4f91a/2/project
SPAWN_EXIT=0
```

## staged launch file
```sh
export COMPACT_ADVISER_DISABLE=1; export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0='/tmp/fm-lab.HpF3nr/state/divert-cursor-z2.git-hooks'; env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_INVOKED_AS '/tmp/fm-lab.HpF3nr/stubbin/cursor-agent' --trust --yolo --model 'cursor-grok-4.6-high' --workspace '/tmp/fm-lab.HpF3nr/pool/.treehouse/project-a4f91a/2/project' "$('/home/jon/.no-mistakes/worktrees/46339c0817e0/01M3H884K1YMR3EMJ21CPSPNKF/bin/fm-operational-input.sh' encode launch-brief < '/tmp/fm-lab.HpF3nr/data/divert-cursor-z2/launch-brief.md')"
```

## task meta
```ini
window=fm-lab-spawn:fm-divert-cursor-z2
endpoint_task_id=divert-cursor-z2
worktree=/tmp/fm-lab.HpF3nr/pool/.treehouse/project-a4f91a/2/project
project=/tmp/fm-lab.HpF3nr/project
harness=cursor
kind=ship
mode=no-mistakes
yolo=off
branch=fm/divert-cursor-z2
tasktmp=/tmp/fm-divert-cursor-z2
model=cursor-grok-4.6-high
effort=high
spawn_gen=s1790527345.3184387.872
```

## worker pane capture
```console
treehouse get
project ➜ treehouse get
A new version of treehouse is available: v1.8.1-0.20260905115643-6e0ac79a026b →
v3.1.0
Run "treehouse update" to update

🌳 Setting up worktree...
🌳 Entered worktree at /tmp/fm-lab.HpF3nr/pool/.treehouse/project-a4f91a/2/proje
ct. Type 'exit' to return.
project ➜ export GOTMPDIR=/tmp/fm-divert-cursor-z2/gotmp
project ➜ export COMPACT_ADVISER_DISABLE=1
project ➜ export BEADS_ACTOR='divert-cursor-z2'
project ➜ export FM_TASK_ID=divert-cursor-z2
project ➜ . '/tmp/fm-divert-cursor-z2+ce88309bf89d73917f0978fc4649266f0b1f72c3f7
cfdc773b713d1c04d7cde7/launch.s1790527345.3184387.872.sh'









```

## argv the stub cursor-agent received in the pane
```console
cursor-agent argv: --trust --yolo --model cursor-grok-4.6-high --workspace /tmp/fm-lab.HpF3nr/pool/.treehouse/project-a4f91a/2/project ⁣FIRSTMATE_OP: v1 launch-brief: # Current worker role contract
```
