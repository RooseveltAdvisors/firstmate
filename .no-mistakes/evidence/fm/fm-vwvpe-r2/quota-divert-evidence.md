## Target 1185560b: tests/fm-spawn-dispatch-profile.test.sh (exit 0)
ok - quota divert to pi rebuilds concrete Pi launch and applies diverted profile
ok - quota divert to cursor rebuilds concrete Cursor launch
ok - same-harness quota divert revalidates the diverted model
ok - quota divert away from pi drops the resolved pi executable
ok - quota divert without standing permission keeps the captain-selected lane
ok - raw launch command runs verbatim when the prober would divert

## Base 6b0f5a07 bin/fm-spawn.sh with test_quota_divert_to_pi_rebuilds_launch only (exit 1)
not ok - quota divert to pi did not rebuild the Pi launch prefix and executable (missing: 'FM_PI_HARNESS=pi '/tmp/fm-spawn-dispatch-profile.Ao1ATW/profile-quota-divert-pi/fake/fakebin/pi' --tui-mode regular')
