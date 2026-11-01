# frozen_string_literal: true

class CreateReportPrivateStorageCleanups < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_report_private_storage_cleanups do |t|
      t.references :decidim_organization, null: false, foreign_key: true, index: { name: "idx_private_cleanup_org" }
      # Historical IDs are not ownership FKs: the original row must be removable.
      t.bigint :attachment_id, :original_blob_id, :replacement_blob_id, null: false
      t.string :original_service_name, null: false
      t.text :original_key_ciphertext, null: false
      t.string :state, null: false, default: "pending"
      t.string :last_error_class
      t.datetime :cleaned_at, :last_attempted_at
      t.timestamps
    end
    add_index :decidim_bih_report_private_storage_cleanups, [:state, :last_attempted_at, :id], name: "idx_private_cleanup_pending"
  end
end
