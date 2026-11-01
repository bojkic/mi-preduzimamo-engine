# frozen_string_literal: true

class AddForwardingFailureMetadataToDecidimBihReports < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_reports, :forwarding_error_class, :string unless column_exists?(:decidim_bih_reports, :forwarding_error_class)
    add_column :decidim_bih_reports, :forwarding_error_message, :string unless column_exists?(:decidim_bih_reports, :forwarding_error_message)
    add_column :decidim_bih_reports, :forwarding_error_code, :string unless column_exists?(:decidim_bih_reports, :forwarding_error_code)
    add_column :decidim_bih_reports, :forwarding_failure_count, :integer, null: false, default: 0 unless column_exists?(:decidim_bih_reports, :forwarding_failure_count)
    add_column :decidim_bih_reports, :forwarding_failed_at, :datetime unless column_exists?(:decidim_bih_reports, :forwarding_failed_at)

    return if index_exists?(
      :decidim_bih_reports,
      [:decidim_organization_id, :status, :forwarding_failed_at],
      name: "idx_bih_reports_forwarding_failures"
    )

    add_index :decidim_bih_reports,
              [:decidim_organization_id, :status, :forwarding_failed_at],
              name: "idx_bih_reports_forwarding_failures"
  end
end
