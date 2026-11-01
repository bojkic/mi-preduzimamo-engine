# frozen_string_literal: true

class AddDecidimBihRaceReview < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_race_editions do |t|
      t.bigint :decidim_organization_id, null: false
      t.string :key, null: false
      t.boolean :scores_visible, null: false, default: true
      t.integer :visibility_version, null: false, default: 0
      t.jsonb :settings, null: false, default: {}
      t.datetime :baseline_at
      t.datetime :captured_at
      t.jsonb :snapshot, null: false, default: {}
      t.string :snapshot_digest
      t.datetime :finalized_at
      t.bigint :finalized_by_id
      t.string :final_digest
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :decidim_bih_race_editions, [:decidim_organization_id, :key], unique: true, name: :idx_bih_race_edition_org_key
    create_table :decidim_bih_race_memberships do |t|
      t.references :edition, null: false, foreign_key: { to_table: :decidim_bih_race_editions }
      t.bigint :decidim_user_id, null: false
      t.bigint :komsiluk_id, null: false
      t.datetime :assigned_at, null: false
      t.datetime :qualified_at
      t.string :provenance, null: false
      t.timestamps
    end
    add_index :decidim_bih_race_memberships, [:edition_id, :decidim_user_id], unique: true, name: :idx_bih_race_membership_user
    create_table :decidim_bih_race_events do |t|
      t.references :edition, null: false, foreign_key: { to_table: :decidim_bih_race_editions }
      t.bigint :actor_id
      t.string :kind, null: false
      t.string :item_key
      t.jsonb :data, null: false, default: {}
      t.timestamps
    end
    add_index :decidim_bih_race_events, [:edition_id, :item_key, :id], name: :idx_bih_race_review_item
    add_column :decidim_bih_race_standings, :edition_key, :string, null: false, default: "2026"
  end
end
