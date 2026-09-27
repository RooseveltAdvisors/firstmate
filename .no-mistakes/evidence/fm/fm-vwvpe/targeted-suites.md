# Targeted behavioral suites run against the target tree (repo's own end-to-end drivers)
```console
$ bash tests/fm-spawn-dispatch-profile.test.sh
# all fm-spawn-dispatch-profile tests passed

$ bash tests/fm-jev-quota-prober.test.sh
ok - all fm-jev-quota-prober tests passed

$ bash tests/fm-route-domain.test.sh
ok - all fm-route-domain tests passed

$ bash tests/fm-jev-guard.test.sh
ok - all fm-jev-guard tests passed

$ bash tests/fm-jev-wake-triage.test.sh
# all fm-jev-wake-triage tests passed

$ bash tests/fm-jev-ci-workflow-guard.test.sh
ok - all fm-jev-ci-workflow-guard tests passed

$ bash tests/fm-capacity-hold.test.sh
# all fm-capacity-hold tests passed

$ bash tests/fm-jev-alert-correlator.test.sh
ok - all fm-jev-alert-correlator tests passed
```
