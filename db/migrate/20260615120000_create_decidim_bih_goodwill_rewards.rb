# frozen_string_literal: true

# Round 25 — table-backed rewards catalog. Until now the catalog of redeemable
# rewards lived only in host config (Decidim::Bih.goodwill_rewards_catalog),
# so an operator could not add/edit/retire a reward without a redeploy. This
# table makes the catalog editable from the admin UI, per organization.
#
# Additive + reversible: existing config-driven rewards keep working until an
# operator imports them (rake decidim_bih:goodwill:import_rewards_catalog) and
# the table gains rows — RewardsCatalog falls back to config while the table is
# empty for the org.
class CreateDecidimBihGoodwillRewards < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_goodwill_rewards do |t|
      t.references :decidim_organization,
                   null: false,
                   foreign_key: { to_table: :decidim_organizations },
                   index: { name: "idx_bih_goodwill_rewards_org" }

      t.string :key, null: false
      t.jsonb :title, null: false, default: {}
      t.jsonb :description, default: {}
      t.integer :cost, null: false, default: 0
      # nil stock = unlimited; integer = max concurrent open/fulfilled slots.
      t.integer :stock
      # nil = no deadline; otherwise a hard redemption cutoff.
      t.datetime :expires_at
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    # One catalog entry per (organization, key); the public/redeem flow resolves
    # a reward by its stable key, so it must be unique within an organization.
    add_index :decidim_bih_goodwill_rewards,
              [:decidim_organization_id, :key],
              unique: true,
              name: "idx_bih_goodwill_rewards_org_key"
  end
end
