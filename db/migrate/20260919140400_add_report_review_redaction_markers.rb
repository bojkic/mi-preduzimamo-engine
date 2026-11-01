# frozen_string_literal: true

class AddReportReviewRedactionMarkers < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_report_dispatches, :data_redacted_at, :datetime
    add_column :decidim_bih_report_review_proposals, :data_redacted_at, :datetime
  end
end
