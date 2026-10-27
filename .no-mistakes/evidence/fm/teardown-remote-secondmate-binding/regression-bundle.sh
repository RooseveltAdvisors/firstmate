#!/usr/bin/env bash
# Targeted regression bundle: pre-existing sibling tests around the two guards
# this change touched (parent-binding resolution, durable parent records,
# retirement guard, promotion's use of teardown parent resolution).
set -u
WORKTREE=$1
fm_regression_bundle() {
  test_secondmate_teardown_requires_parent_binding
  test_local_secondmate_seed_publishes_parent_before_identity
  test_secondmate_teardown_resolves_parent_from_durable_record_when_env_lost
  test_secondmate_teardown_durable_record_missing_parent_registration_still_refuses
  test_secondmate_teardown_durable_record_with_unknown_field_succeeds
  test_secondmate_teardown_rejects_conflicting_live_and_durable_parent_bindings
  test_secondmate_teardown_rejects_unsafe_durable_parent_records
  test_secondmate_teardown_rejects_nul_bearing_durable_parent_record
  test_secondmate_parent_binding_matches_literal_id
  test_secondmate_promotion_uses_teardown_parent_resolution
  test_retire_after_secondmate_home_removal
  test_retire_refuses_unbound_existing_secondmate
  test_retire_refuses_reassigned_secondmate_home
}
export -f fm_regression_bundle
cd "$WORKTREE" || exit 1
FM_TEST_ONLY=fm_regression_bundle bash tests/fm-public-followup.test.sh
