# frozen_string_literal: true

class AddReportDetailsAndRoutingGuides < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_reports, :details, :jsonb, null: false, default: {}
    create_table :decidim_bih_report_routing_guides do |t|
      t.references :decidim_organization, null: false, foreign_key: true, index: { name: "idx_report_routing_guides_decidim_organiz_32b9d7" }
      t.string :key, null: false
      t.string :title, null: false
      t.text :body_sr, null: false
      t.string :categories, array: true, default: [], null: false
      t.string :approved_recipient_keys, array: true, default: [], null: false
      t.boolean :active, default: false, null: false
      t.integer :version, default: 1, null: false
      t.references :approved_by, foreign_key: { to_table: :decidim_users }
      t.timestamps
    end
    add_index :decidim_bih_report_routing_guides, [:decidim_organization_id, :key], unique: true, name: 'report_routing_guide_identity'
  end
end
