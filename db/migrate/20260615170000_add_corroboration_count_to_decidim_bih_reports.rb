# frozen_string_literal: true

# Public corroboration counter for the "Bice riseno" reports. When a citizen
# files what the WEB intake detects as a likely duplicate, they can instead
# "me too" the existing report — incrementing this counter — rather than creating
# a fresh report. It is a simple public tally (NOT tied to the binding vote) used
# to show "N gradjana je prijavilo isto" on the report's tracker page.
class AddCorroborationCountToDecidimBihReports < ActiveRecord::Migration[7.2]
  def change
    return if column_exists?(:decidim_bih_reports, :corroboration_count)

    add_column :decidim_bih_reports, :corroboration_count, :integer, default: 0, null: false
  end
end
