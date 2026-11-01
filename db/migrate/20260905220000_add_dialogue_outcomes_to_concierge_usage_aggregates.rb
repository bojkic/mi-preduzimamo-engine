# frozen_string_literal: true

# Adds fixed daily outcome counters to the existing privacy-safe aggregate.
# Existing rows remain zero: no historical conversation outcome is inferred.
class AddDialogueOutcomesToConciergeUsageAggregates < ActiveRecord::Migration[7.2]
  TABLE = :decidim_bih_concierge_usage_aggregates
  COUNTERS = [
    :resolution_answered_count, :resolution_clarification_count,
    :resolution_handoff_count, :resolution_draft_count,
    :resolution_submitted_count, :resolution_cancelled_count,
    :resolution_unsupported_count, :resolution_source_unavailable_count,
    :resolution_delivery_failed_count, :handoff_offered_count,
    :handoff_completed_count, :grounded_answer_count, :action_receipt_count
  ].freeze
  CONSTRAINT = "chk_bih_concierge_dialogue_counts"

  def up
    change_table TABLE, bulk: true do |table|
      COUNTERS.each { |counter| table.bigint counter, null: false, default: 0 }
    end
    add_check_constraint TABLE,
                         COUNTERS.map { |counter| "#{counter} >= 0" }.join(" AND "),
                         name: CONSTRAINT
  end

  def down
    remove_check_constraint TABLE, name: CONSTRAINT
    change_table TABLE, bulk: true do |table|
      COUNTERS.each { |counter| table.remove counter }
    end
  end
end
