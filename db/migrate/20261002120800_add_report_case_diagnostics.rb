# frozen_string_literal: true

class AddReportCaseDiagnostics < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_report_review_proposals, :failure_reason, :string
    add_column :decidim_bih_report_review_proposals, :repair_attempted, :boolean, default: false, null: false
    create_table :decidim_bih_case_usage_days do |t|
      t.date :day, null: false
      t.decimal :reserved_usd, precision: 14, scale: 8, default: 0, null: false
      t.timestamps
    end
    add_index :decidim_bih_case_usage_days, :day, unique: true
    add_check_constraint :decidim_bih_case_usage_days, 'reserved_usd >= 0', name: 'case_usage_nonnegative'
  end
end
