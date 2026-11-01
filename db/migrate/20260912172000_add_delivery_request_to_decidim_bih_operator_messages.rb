# frozen_string_literal: true

class AddDeliveryRequestToDecidimBihOperatorMessages < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_operator_messages, :delivery_request_digest, :string
    add_index :decidim_bih_operator_messages, [:decidim_organization_id, :delivery_request_digest],
              unique: true, where: "delivery_request_digest IS NOT NULL", name: "idx_bih_operator_delivery_request"
  end
end
