# frozen_string_literal: true

class CreateDecidimBihRewardFulfillmentEvents < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_goodwill_reward_fulfillment_events do |t|
      t.references :decidim_bih_goodwill_reward_fulfillment,
                   null: false,
                   foreign_key: { to_table: :decidim_bih_goodwill_reward_fulfillments },
                   index: { name: "idx_bih_reward_events_fulfillment" }
      t.references :decidim_organization,
                   null: false,
                   foreign_key: true,
                   index: { name: "idx_bih_reward_events_org" }
      t.references :decidim_user,
                   null: true,
                   foreign_key: true,
                   index: { name: "idx_bih_reward_events_actor" }
      t.string :event_type, null: false
      t.string :source, null: false
      t.string :actor_role
      t.datetime :occurred_at, null: false
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :decidim_bih_goodwill_reward_fulfillment_events,
              [:decidim_bih_goodwill_reward_fulfillment_id, :occurred_at, :id],
              name: "idx_bih_reward_events_fulfillment_time"
    add_index :decidim_bih_goodwill_reward_fulfillment_events,
              [:decidim_organization_id, :event_type, :occurred_at],
              name: "idx_bih_reward_events_org_type_time"
  end
end
