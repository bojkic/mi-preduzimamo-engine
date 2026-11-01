# frozen_string_literal: true

require "test_helper"

# Task 6: schema foundation for a threshold reward that does not deduct
# points. Covers the three new migrations: deducts_points/auto_issue flags on
# rewards, the nullable ledger transaction on fulfillments, and the launch
# invitation fields plus their partial unique indexes.
class LaunchInvitationMigrationsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  MIGRATIONS_ROOT = File.join(ROOT, "db/migrate")

  REWARDS_MIGRATION = "20260831100000_add_deducts_points_to_goodwill_rewards.rb"
  NULLABLE_TRANSACTION_MIGRATION = "20260831100100_allow_pointless_reward_fulfillments.rb"
  LAUNCH_INVITATION_MIGRATION = "20260831100200_add_launch_invitation_fields_to_fulfillments.rb"

  def test_rewards_gain_deducts_points_and_auto_issue_flags_with_safe_defaults
    assert_migration_includes(
      REWARDS_MIGRATION,
      "add_column :decidim_bih_goodwill_rewards, :deducts_points, :boolean",
      "null: false, default: true",
      "add_column :decidim_bih_goodwill_rewards, :auto_issue_at_threshold, :boolean",
      "null: false, default: false"
    )
  end

  def test_reward_fulfillment_transaction_becomes_nullable_without_dropping_the_unique_index
    assert_migration_includes(
      NULLABLE_TRANSACTION_MIGRATION,
      "change_column_null :decidim_bih_goodwill_reward_fulfillments",
      ":decidim_bih_goodwill_transaction_id, true"
    )
    refute_includes migration_content(NULLABLE_TRANSACTION_MIGRATION), "remove_index"
  end

  def test_nullable_transaction_migration_refuses_to_rollback_when_rows_would_be_destroyed
    content = migration_content(NULLABLE_TRANSACTION_MIGRATION)

    assert_includes content, "def down"
    assert_includes content, "SELECT COUNT(*) FROM decidim_bih_goodwill_reward_fulfillments"
    assert_includes content, "WHERE decidim_bih_goodwill_transaction_id IS NULL"
    assert_includes content, "raise ActiveRecord::IrreversibleMigration"
    assert_includes content, "change_column_null :decidim_bih_goodwill_reward_fulfillments",
                    ":decidim_bih_goodwill_transaction_id, false"
  end

  def test_nullable_transaction_migration_down_path_never_unconditionally_deletes_rows
    refute_includes migration_content(NULLABLE_TRANSACTION_MIGRATION), "DELETE FROM"
  end

  def test_launch_invitation_columns_are_added
    assert_migration_includes(
      LAUNCH_INVITATION_MIGRATION,
      "add_column :decidim_bih_goodwill_reward_fulfillments, :auto_issued, :boolean",
      "null: false, default: false",
      "add_column :decidim_bih_goodwill_reward_fulfillments, :entry_code, :string",
      "add_column :decidim_bih_goodwill_reward_fulfillments, :issued_at, :datetime",
      "add_column :decidim_bih_goodwill_reward_fulfillments, :confirmation_deadline_at, :datetime",
      "add_column :decidim_bih_goodwill_reward_fulfillments, :attendance_confirmed_at, :datetime",
      "add_column :decidim_bih_goodwill_reward_fulfillments, :entry_code_used_at, :datetime"
    )
  end

  def test_auto_issued_idempotency_index_is_partial_and_does_not_constrain_manual_redemptions
    assert_migration_includes(
      LAUNCH_INVITATION_MIGRATION,
      "idx_bih_auto_issued_one_per_user_reward",
      "[:decidim_organization_id, :decidim_user_id, :reward_key]",
      "unique: true",
      'where: "auto_issued = TRUE"'
    )
  end

  def test_entry_code_index_is_unique_per_organization_and_partial
    assert_migration_includes(
      LAUNCH_INVITATION_MIGRATION,
      "idx_bih_reward_fulfillments_entry_code",
      "[:decidim_organization_id, :entry_code]",
      "unique: true",
      'where: "entry_code IS NOT NULL"'
    )
  end

  def test_pending_confirmation_index_targets_unconfirmed_auto_issued_rows
    assert_migration_includes(
      LAUNCH_INVITATION_MIGRATION,
      "idx_bih_launch_invitation_pending_confirmation",
      "[:decidim_organization_id, :confirmation_deadline_at]",
      'where: "auto_issued = TRUE AND attendance_confirmed_at IS NULL"'
    )
  end

  def test_new_index_names_fit_postgresql_63_byte_identifier_limit
    %w(
      idx_bih_auto_issued_one_per_user_reward
      idx_bih_reward_fulfillments_entry_code
      idx_bih_launch_invitation_pending_confirmation
    ).each do |name|
      assert name.bytesize <= 63, "#{name} exceeds PostgreSQL's 63-byte identifier limit"
    end
  end

  private

  def migration_content(name)
    File.read(File.join(MIGRATIONS_ROOT, name))
  end

  def assert_migration_includes(name, *snippets)
    content = migration_content(name)

    snippets.each do |snippet|
      assert_includes content, snippet
    end
  end
end
