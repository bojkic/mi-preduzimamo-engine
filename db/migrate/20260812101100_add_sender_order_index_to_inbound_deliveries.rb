# frozen_string_literal: true

class AddSenderOrderIndexToInboundDeliveries < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  TABLE_NAME = :decidim_bih_viber_inbound_deliveries
  INDEX_NAME = "idx_bih_inbound_sender_order"
  COLUMNS = %w(decidim_organization_id channel sender_digest received_at id).freeze

  def up
    existing = connection.indexes(TABLE_NAME).find { |index| index.name == INDEX_NAME }
    return if existing&.valid? && existing.columns == COLUMNS

    if existing&.valid?
      raise ActiveRecord::MigrationError,
            "#{INDEX_NAME} exists with unexpected columns: #{existing.columns.join(", ")}"
    end

    remove_index TABLE_NAME, name: INDEX_NAME, algorithm: :concurrently if existing

    add_index TABLE_NAME,
              COLUMNS,
              name: INDEX_NAME,
              algorithm: :concurrently
  end

  def down
    remove_index TABLE_NAME,
                 name: INDEX_NAME,
                 algorithm: :concurrently,
                 if_exists: true
  end
end
