# frozen_string_literal: true

# Keeps the operational report coordinates exact while making the public map
# approximate by default. Citizens may explicitly opt in to publishing the
# exact point when the precise location is important to understanding an issue.
class AddPublicLocationChoiceToBihReports < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_reports, :public_location_exact, :boolean, null: false, default: false
  end
end
