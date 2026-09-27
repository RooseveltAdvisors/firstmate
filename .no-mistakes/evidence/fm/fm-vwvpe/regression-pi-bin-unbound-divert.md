# Regression reproduction: PI_BIN unbound on a quota divert to pi (the named house spawn defect)

Pre-fix code = bin/fm-spawn.sh from commit 0a89c3ee (Jev quota prober wired in, before
60626c03 'resolve PI template and PI_BIN for cross-harness quota diverts' and
1e1dbd16 'repair pi quota divert launch'). The tree was snapshotted to /tmp, only
bin/fm-spawn.sh swapped for the pre-fix version, and the hardcoded pre-fix prober path
replaced by the divert-pi stub (the fix added the FM_TEST_JEV_PROBER_PATH seam).
The SAME test driver then ran against both trees.

## PRE-FIX (defect present): test FAILS
```console
not ok - quota divert to pi should succeed: jev-quota-prober: automatically diverted codex:codex/gpt-5 to viable lane pi:openai-codex/gpt-5.6-sol
warning: /tmp/fm-spawn-dispatch-profile.rv0NbU/profile-quota-divert-pi/home/data/profile-quota-divert-pi-z8e/launch-brief.md records no ship branch; defaulting to legacy branch fm/profile-quota-divert-pi-z8e
warning: /tmp/fm-spawn-dispatch-profile.rv0NbU/profile-quota-divert-pi/home/data/profile-quota-divert-pi-z8e/launch-brief.md records no delivery contract line (scaffolded before ship briefs recorded one); launching on the explicit --mode no-mistakes - confirm its definition of done matches
/tmp/fm-spawn-dispatch-profile.rv0NbU/profile-quota-divert-pi/fake/fakebin/timeout: line 3: exec: 1: not found
/tmp/fm-spawn-dispatch-profile.rv0NbU/profile-quota-divert-pi/fake/fakebin/timeout: line 3: exec: 1: not found
/tmp/fm-prefix-regress/bin/fm-spawn.sh: line 5064: PI_BIN: unbound variable: expected exit 0, got 1
```

## TARGET (4e2604d4): same driver PASSES
```console
ok - quota divert to pi rebuilds concrete Pi launch and applies diverted profile
# selected divert tests finished
```
