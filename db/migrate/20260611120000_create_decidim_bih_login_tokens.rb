# frozen_string_literal: true

class CreateDecidimBihLoginTokens < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_login_tokens do |t|
      t.references :decidim_user, null: false, index: true,
                                  foreign_key: { to_table: :decidim_users }
      t.references :decidim_organization, null: false, index: true,
                                          foreign_key: { to_table: :decidim_organizations }
      t.string :purpose, null: false
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end

    add_index :decidim_bih_login_tokens, :token_digest, unique: true
  end
end
