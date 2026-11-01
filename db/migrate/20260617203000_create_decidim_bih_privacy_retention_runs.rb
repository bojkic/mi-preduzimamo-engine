# frozen_string_literal: true

class CreateDecidimBihPrivacyRetentionRuns < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_privacy_retention_runs do |t|
      t.references :decidim_organization,
                   null: false,
                   index: { name: "idx_bih_privacy_retention_runs_on_org" },
                   foreign_key: { to_table: :decidim_organizations }
      t.string :status, null: false, default: "running"
      t.boolean :dry_run, null: false, default: true
      t.string :source, null: false, default: "service"
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.integer :total, null: false, default: 0
      t.jsonb :counts, null: false, default: {}
      t.jsonb :cutoffs, null: false, default: {}
      t.string :error_class
      t.text :error_message

      t.timestamps
    end

    add_index :decidim_bih_privacy_retention_runs,
              [:decidim_organization_id, :started_at, :id],
              name: "idx_bih_privacy_retention_runs_org_started"
    add_index :decidim_bih_privacy_retention_runs,
              [:decidim_organization_id, :status, :started_at],
              name: "idx_bih_privacy_retention_runs_org_status_started"
  end
end
