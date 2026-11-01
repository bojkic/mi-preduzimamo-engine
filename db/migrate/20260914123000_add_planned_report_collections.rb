# frozen_string_literal: true

class AddPlannedReportCollections < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_report_collections do |t|
      t.references :decidim_organization, null: false, foreign_key: { to_table: :decidim_organizations }, index: { name: :idx_bih_report_collections_org }
      t.string :title, null: false
      t.string :topic, null: false
      t.string :state, null: false, default: "collecting"
      t.references :assigned_to, foreign_key: { to_table: :decidim_users }
      t.datetime :review_due_at
      t.text :summary
      t.text :submission_snapshot
      t.string :recipient
      t.string :external_reference
      t.datetime :submitted_at
      t.timestamps
    end
    change_table :decidim_bih_reports, bulk: true do |t|
      t.references :report_collection, foreign_key: { to_table: :decidim_bih_report_collections }, index: { name: :idx_bih_reports_collection }
      t.string :report_subtype
      t.string :location_kind, null: false, default: "description"
      t.float :location_end_latitude
      t.float :location_end_longitude
      t.jsonb :original_location, null: false, default: {}
      t.datetime :location_reviewed_at
      t.references :location_reviewed_by, foreign_key: { to_table: :decidim_users }, index: false
    end
  end
end
