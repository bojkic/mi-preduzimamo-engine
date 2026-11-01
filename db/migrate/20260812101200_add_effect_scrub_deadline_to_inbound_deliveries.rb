# frozen_string_literal: true

class AddEffectScrubDeadlineToInboundDeliveries < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  TABLE_NAME = :decidim_bih_viber_inbound_deliveries
  INDEX_NAME = "idx_bih_inbound_effect_scrub"
  COLUMNS = %w(phase next_effect_scrub_at).freeze

  def up
    add_column TABLE_NAME, :next_effect_scrub_at, :datetime unless column_exists?(TABLE_NAME, :next_effect_scrub_at)

    existing = connection.indexes(TABLE_NAME).find { |index| index.name == INDEX_NAME }
    return if existing&.valid? && existing.columns == COLUMNS

    if existing&.valid?
      raise ActiveRecord::MigrationError,
            "#{INDEX_NAME} exists with unexpected columns: #{existing.columns.join(", ")}"
    end

    remove_index TABLE_NAME, name: INDEX_NAME, algorithm: :concurrently if existing
    add_index TABLE_NAME, COLUMNS, name: INDEX_NAME, algorithm: :concurrently
  end

  def down
    remove_index TABLE_NAME, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
    remove_column TABLE_NAME, :next_effect_scrub_at if column_exists?(TABLE_NAME, :next_effect_scrub_at)
  end
end
