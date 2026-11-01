# frozen_string_literal: true

# The new counter starts at zero. Historical "answered" safety turns cannot
# be reclassified from aggregates; preserve all old counts and bucket rows.
class AddSafetyGuidanceToConciergeUsageAggregates < ActiveRecord::Migration[7.2]
  TABLE = :decidim_bih_concierge_usage_aggregates
  COLUMN = :resolution_safety_guidance_count
  CONSTRAINT = "chk_bih_concierge_safety_guidance_count"

  def up
    add_column TABLE, COLUMN, :bigint, default: 0, null: false
    add_check_constraint TABLE, "#{COLUMN} >= 0", name: CONSTRAINT
  end

  def down
    remove_check_constraint TABLE, name: CONSTRAINT
    remove_column TABLE, COLUMN
  end
end
