# frozen_string_literal: true

# Mirrors the city's external Sistem 48 resolution status onto our reports.
# These columns are SEPARATE from the platform's own `status` lifecycle column:
# `status` tracks our intake/forwarding state, while these store the status the
# city publishes back on the public bijeljina48.org archive.
class AddSistem48StatusToDecidimBihReports < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_reports, :sistem48_status, :string unless column_exists?(:decidim_bih_reports, :sistem48_status)

    add_column :decidim_bih_reports, :sistem48_synced_at, :datetime unless column_exists?(:decidim_bih_reports, :sistem48_synced_at)
  end
end
