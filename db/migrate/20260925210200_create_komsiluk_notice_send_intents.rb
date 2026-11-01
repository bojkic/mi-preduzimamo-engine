# frozen_string_literal: true

class CreateKomsilukNoticeSendIntents < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_komsiluk_send_intents do |t|
      t.references :decidim_organization, null: false, foreign_key: true, index: { name: "idx_komsiluk_intents_org" }
      t.references :decidim_user, null: false, foreign_key: true, index: { name: "idx_komsiluk_intents_actor" }
      t.string :kind, null: false
      t.string :state, null: false, default: "preview"
      t.string :publication_key, null: false
      t.string :preview_digest, null: false
      t.text :payload_ciphertext
      t.datetime :payload_scrubbed_at
      t.datetime :expires_at, null: false
      t.datetime :confirmed_at
      t.integer :recipients_count, null: false, default: 0
      t.integer :reserved_minor, null: false, default: 0
      t.timestamps
    end
    add_index :decidim_bih_komsiluk_send_intents, [:decidim_organization_id, :publication_key, :kind], name: "idx_komsiluk_intents_publication"

    create_table :decidim_bih_komsiluk_phone_deliveries do |t|
      t.references :decidim_organization, null: false, foreign_key: true, index: { name: "idx_komsiluk_phone_org" }
      t.references :decidim_user, null: false, foreign_key: true, index: { name: "idx_komsiluk_phone_user" }
      t.bigint :send_intent_id, null: false
      t.bigint :platform_delivery_id, null: false
      t.string :status, null: false, default: "pending"
      t.jsonb :channels, null: false, default: []
      t.string :destination_digest, null: false
      t.jsonb :provider_message_ids, null: false, default: []
      t.jsonb :previous_attempts, null: false, default: []
      t.datetime :due_at, null: false
      t.datetime :expires_at, null: false
      t.datetime :attempted_at
      t.datetime :delivered_at
      t.string :reason
      t.datetime :provider_checked_at
      t.string :provider_status
      t.integer :reserved_minor, null: false, default: 0
      t.datetime :budget_released_at
      t.timestamps
    end
    add_foreign_key :decidim_bih_komsiluk_phone_deliveries, :decidim_bih_komsiluk_send_intents, column: :send_intent_id
    add_foreign_key :decidim_bih_komsiluk_phone_deliveries, :decidim_bih_platform_deliveries, column: :platform_delivery_id, on_delete: :cascade
    add_index :decidim_bih_komsiluk_phone_deliveries, :platform_delivery_id, unique: true, name: "idx_komsiluk_phone_receipt_unique"
    add_index :decidim_bih_komsiluk_phone_deliveries, [:status, :due_at], name: "idx_komsiluk_phone_pending"

    create_table :decidim_bih_komsiluk_sms_budgets do |t|
      t.references :decidim_organization, null: false, foreign_key: true, index: false
      t.date :budget_on, null: false
      t.string :currency, null: false
      t.integer :reserved_minor, null: false, default: 0
      t.timestamps
    end
    add_index :decidim_bih_komsiluk_sms_budgets, [:decidim_organization_id, :budget_on, :currency], unique: true, name: "idx_komsiluk_sms_budget_unique"
    add_check_constraint :decidim_bih_komsiluk_sms_budgets, "reserved_minor >= 0", name: "komsiluk_sms_budget_nonnegative"
  end
end
