# frozen_string_literal: true

class CreateDecidimBihAccountNotifications < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_account_notifications do |t|
      t.references :decidim_organization, null: false, foreign_key: { to_table: :decidim_organizations }, index: false
      t.references :decidim_user, null: false, foreign_key: { to_table: :decidim_users, on_delete: :cascade }, index: false
      t.string :topic, null: false
      t.string :deduplication_digest, null: false
      t.text :payload_ciphertext, null: false
      t.string :status, null: false, default: "pending"
      t.jsonb :channels, null: false, default: []
      t.jsonb :provider_message_ids, null: false, default: []
      t.string :reason
      t.datetime :expires_at, null: false
      t.datetime :attempted_at
      t.datetime :delivered_at
      t.timestamps
    end
    add_index :decidim_bih_account_notifications, [:decidim_organization_id, :decidim_user_id, :deduplication_digest], unique: true, name: "idx_bih_account_notifications_dedupe"
    add_index :decidim_bih_account_notifications, [:decidim_user_id, :created_at], name: "idx_bih_account_notifications_user_time"
  end
end
