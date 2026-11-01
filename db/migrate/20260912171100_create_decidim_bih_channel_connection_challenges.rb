# frozen_string_literal: true

class CreateDecidimBihChannelConnectionChallenges < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_channel_connection_challenges do |t|
      t.references :decidim_organization, null: false, foreign_key: true, index: { name: "mi_challenge_org" }
      t.references :decidim_user, null: false, foreign_key: true, index: { name: "mi_challenge_user" }
      t.string :channel, null: false
      t.string :business_sender, null: false
      t.string :token_digest, null: false
      t.integer :confirmation_attempts, null: false, default: 0
      t.string :confirmation_digest
      t.text :recipient_ciphertext
      t.datetime :last_inbound_at
      t.datetime :expires_at, null: false
      t.datetime :proved_at
      t.datetime :consumed_at
      t.timestamps
    end
    add_index :decidim_bih_channel_connection_challenges, :token_digest, unique: true, name: "mi_channel_challenge_token"
  end
end
