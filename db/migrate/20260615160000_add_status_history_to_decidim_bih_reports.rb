# frozen_string_literal: true

# Adds a per-report append-only lifecycle log so the public status page can
# render a resolution timeline and the city's responsiveness becomes visible.
# Each entry is the PII-free pair { "status" => ..., "at" => <iso8601> },
# appended by the model on every status transition (admin, archive sync,
# intake — any write path), so the timeline is sourced from a single column
# rather than reconstructed from scattered per-status timestamps.
class AddStatusHistoryToDecidimBihReports < ActiveRecord::Migration[7.2]
  def up
    return if column_exists?(:decidim_bih_reports, :status_history)

    add_column :decidim_bih_reports, :status_history, :jsonb, default: [], null: false
  end

  def down
    remove_column :decidim_bih_reports, :status_history if column_exists?(:decidim_bih_reports, :status_history)
  end
end
