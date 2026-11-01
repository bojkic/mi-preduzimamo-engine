# frozen_string_literal: true

class AddChannelToDecidimBihViberInboundDeliveries < ActiveRecord::Migration[7.2]
  INDEX_NAME = "idx_bih_viber_inbound_org_message"

  def up
    add_column :decidim_bih_viber_inbound_deliveries,
               :channel,
               :string,
               null: false,
               default: "viber"

    remove_index :decidim_bih_viber_inbound_deliveries, name: INDEX_NAME
    add_index :decidim_bih_viber_inbound_deliveries,
              [:decidim_organization_id, :channel, :provider_message_key],
              unique: true,
              name: INDEX_NAME
  end

  def down
    remove_index :decidim_bih_viber_inbound_deliveries, name: INDEX_NAME
    add_index :decidim_bih_viber_inbound_deliveries,
              [:decidim_organization_id, :provider_message_key],
              unique: true,
              name: INDEX_NAME
    remove_column :decidim_bih_viber_inbound_deliveries, :channel
  end
end
