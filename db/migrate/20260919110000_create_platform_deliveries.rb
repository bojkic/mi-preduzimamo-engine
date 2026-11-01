# frozen_string_literal: true

class CreatePlatformDeliveries < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_platform_deliveries do |t|
      t.references :decidim_organization, null: false, foreign_key: true, index: { name: :idx_platform_delivery_org }
      t.references :decidim_user, null: false, foreign_key: true, index: { name: :idx_platform_delivery_user }
      t.string :identity, null: false
      t.datetime :expires_at, null: false
      t.datetime :deadline_at, null: false
      t.datetime :fallback_requested_at
      t.jsonb :fallback_context, null: false, default: {}
      t.datetime :inbox_created_at
      t.datetime :acknowledged_at
      t.string :acknowledgment_kind
      t.datetime :push_queued_at
      t.bigint :push_intent_id
      t.bigint :account_notification_id
      t.timestamps
    end
    add_index :decidim_bih_platform_deliveries, [:decidim_organization_id, :decidim_user_id, :identity], unique: true, name: :idx_platform_delivery_identity
  end
end
