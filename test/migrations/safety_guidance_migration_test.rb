# frozen_string_literal: true

require "test_helper"
require "active_record"
require_relative "../../db/migrate/20260915200000_add_safety_guidance_to_concierge_usage_aggregates"

class SafetyGuidanceMigrationTest < Minitest::Test
  Migration = AddSafetyGuidanceToConciergeUsageAggregates

  def test_up_only_adds_a_zero_default_counter_and_its_nonnegative_constraint
    migration, operations = recording_migration
    migration.up
    assert_equal [
      [:add_column, Migration::TABLE, :resolution_safety_guidance_count, :bigint, { default: 0, null: false }],
      [:add_check_constraint, Migration::TABLE, "resolution_safety_guidance_count >= 0", { name: Migration::CONSTRAINT }]
    ], operations
  end

  def test_down_removes_only_the_new_constraint_and_counter
    migration, operations = recording_migration
    migration.down
    assert_equal [
      [:remove_check_constraint, Migration::TABLE, { name: Migration::CONSTRAINT }],
      [:remove_column, Migration::TABLE, :resolution_safety_guidance_count, {}]
    ], operations
  end

  private

  def recording_migration
    operations = []
    migration = Migration.new
    [:add_column, :add_check_constraint, :remove_check_constraint, :remove_column].each do |operation|
      migration.define_singleton_method(operation) { |*args, **options| operations << [operation, *args, options] }
    end
    migration.define_singleton_method(:execute) { |*| raise "Historical counter updates are forbidden" }
    [migration, operations]
  end
end
