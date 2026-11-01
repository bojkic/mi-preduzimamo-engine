# frozen_string_literal: true

class CreateDecidimBihViberInboundDeliveries < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_viber_inbound_deliveries do |t|
      t.references :decidim_organization,
                   null: false,
                   index: { name: "idx_bih_viber_inbound_on_org" },
                   foreign_key: { to_table: :decidim_organizations }
      t.string :provider_message_key, null: false
      t.string :sender_digest
      t.text :encrypted_payload
      t.string :state, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.string :error_class
      t.datetime :received_at, null: false
      t.datetime :processed_at
      t.datetime :expires_at, null: false
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_index :decidim_bih_viber_inbound_deliveries,
              [:decidim_organization_id, :provider_message_key],
              unique: true,
              name: "idx_bih_viber_inbound_org_message"
    add_index :decidim_bih_viber_inbound_deliveries,
              [:state, :received_at],
              name: "idx_bih_viber_inbound_state_received"
    add_index :decidim_bih_viber_inbound_deliveries,
              :expires_at,
              name: "idx_bih_viber_inbound_expires"
  end
end
