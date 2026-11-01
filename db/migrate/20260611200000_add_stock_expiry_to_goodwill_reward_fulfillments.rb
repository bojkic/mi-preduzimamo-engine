# frozen_string_literal: true

# Round 11, Item 1 — expose reward expiry timestamp on fulfillments so the
# cancel-expired-fulfillments rake task can efficiently find rows that belong
# to a now-expired reward. No stock column here: stock is catalog-config only
# (counted at runtime against open fulfillments) and is not stored per-row.
class AddStockExpiryToGoodwillRewardFulfillments < ActiveRecord::Migration[7.2]
  def change
    # Snapshot the reward's expires_at at redemption time so the rake task
    # can find rows without re-resolving catalog config per row.
    add_column :decidim_bih_goodwill_reward_fulfillments, :reward_expires_at, :datetime

    add_index :decidim_bih_goodwill_reward_fulfillments,
              [:decidim_organization_id, :reward_expires_at, :status],
              name: "idx_bih_reward_fulfillments_expiry_status",
              where: "reward_expires_at IS NOT NULL"
  end
end
