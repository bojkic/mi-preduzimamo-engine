# frozen_string_literal: true

class AddKomsilukDeliveryReceiptEvidence < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_komsiluk_posts, :notification_capture_identity, :string
    add_reference :decidim_bih_platform_deliveries, :komsiluk_post, foreign_key: { to_table: :decidim_bih_komsiluk_posts, on_delete: :nullify },
                                                                    index: { name: "idx_platform_delivery_komsiluk_post" }
    add_column :decidim_bih_platform_deliveries, :publication_revision, :integer
    add_column :decidim_bih_platform_deliveries, :cancelled_at, :datetime
    add_column :decidim_bih_platform_deliveries, :cancellation_reason, :string
    add_column :decidim_bih_platform_deliveries, :browser_displayed_at, :datetime
    add_column :decidim_bih_platform_deliveries, :inbox_read_at, :datetime
    add_column :decidim_bih_platform_deliveries, :notification_dispatched_at, :datetime
    add_column :decidim_bih_platform_deliveries, :notification_id, :bigint
    add_index :decidim_bih_platform_deliveries, :notification_id, name: "idx_platform_delivery_notification"
  end
end
