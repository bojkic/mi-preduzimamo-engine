# frozen_string_literal: true

# Mutable operational queue for reward redemptions. The point spend itself stays
# immutable in decidim_bih_goodwill_transactions; this table tracks the manual
# handover state (reserved/fulfilled/canceled/reversed).
class CreateDecidimBihGoodwillRewardFulfillments < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_goodwill_reward_fulfillments do |t|
      t.references :decidim_organization,
                   null: false,
                   foreign_key: { to_table: :decidim_organizations },
                   index: { name: "idx_bih_reward_fulfillments_org" }
      t.references :decidim_bih_goodwill_transaction,
                   null: false,
                   foreign_key: { to_table: :decidim_bih_goodwill_transactions },
                   index: {
                     unique: true,
                     name: "idx_bih_reward_fulfillments_transaction"
                   }
      t.references :decidim_user,
                   null: false,
                   foreign_key: { to_table: :decidim_users },
                   index: { name: "idx_bih_reward_fulfillments_user" }
      t.references :handled_by,
                   foreign_key: { to_table: :decidim_users },
                   index: { name: "idx_bih_reward_fulfillments_handler" }

      t.string :reward_key, null: false
      t.integer :cost, null: false
      t.string :status, null: false, default: "requested"
      t.datetime :handled_at
      t.text :notes

      t.timestamps
    end

    add_index :decidim_bih_goodwill_reward_fulfillments,
              [:decidim_organization_id, :status, :created_at, :id],
              name: "idx_bih_reward_fulfillments_org_status_created"
    add_index :decidim_bih_goodwill_reward_fulfillments,
              [:decidim_organization_id, :decidim_user_id, :created_at, :id],
              name: "idx_bih_reward_fulfillments_org_user_created"
  end
end
