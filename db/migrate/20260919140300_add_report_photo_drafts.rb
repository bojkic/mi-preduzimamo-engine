# frozen_string_literal: true

class AddReportPhotoDrafts < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_report_photo_drafts do |t|
      t.references :organization, null: false, foreign_key: { to_table: :decidim_organizations }
      t.references :consumed_report, foreign_key: { to_table: :decidim_bih_reports }
      t.string :owner_digest, null: false
      t.datetime :expires_at, null: false
      t.timestamps
      t.index :expires_at
    end
  end
end
