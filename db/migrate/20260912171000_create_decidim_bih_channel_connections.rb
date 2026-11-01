# frozen_string_literal: true

class CreateDecidimBihChannelConnections < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_channel_connections do |t|
      t.references :decidim_organization, null: false, foreign_key: true, index: { name: "mi_connection_org" }
      t.references :decidim_user, null: false, foreign_key: true, index: { name: "mi_connection_user" }
      t.string :channel, null: false
      t.string :business_sender, null: false
      t.string :recipient_digest, null: false
      t.text :recipient_ciphertext, null: false
      t.datetime :verified_at, null: false
      t.datetime :revoked_at
      t.datetime :last_inbound_at
      t.timestamps
    end
    add_index :decidim_bih_channel_connections, [:decidim_organization_id, :channel, :business_sender, :recipient_digest], unique: true, where: "revoked_at IS NULL",
                                                                                                                           name: "mi_channel_active_recipient"
    add_index :decidim_bih_channel_connections, [:decidim_organization_id, :channel, :business_sender, :decidim_user_id], unique: true, where: "revoked_at IS NULL",
                                                                                                                          name: "mi_channel_active_user"
  end
end
