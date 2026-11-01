# frozen_string_literal: true

class AddRequestKeyToRewardFulfillments < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_goodwill_reward_fulfillments, :request_key, :string
    add_index :decidim_bih_goodwill_reward_fulfillments,
              [:decidim_organization_id, :decidim_user_id, :request_key],
              unique: true,
              where: "request_key IS NOT NULL",
              name: "idx_bih_reward_fulfillments_request_key"
  end
end
