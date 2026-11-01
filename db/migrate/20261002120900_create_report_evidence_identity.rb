# frozen_string_literal: true

class CreateReportEvidenceIdentity < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_report_evidence_items do |t|
      t.references :report, null: false, foreign_key: { to_table: :decidim_bih_reports }
      t.string :source, null: false
      t.bigint :source_id
      t.references :blob, null: false, foreign_key: { to_table: :active_storage_blobs }
      t.string :checksum, null: false
      t.string :content_type, null: false
      t.bigint :byte_size, null: false
      t.jsonb :assessment, null: false, default: {}
      t.string :sensitive_flags, array: true, null: false, default: []
      t.timestamps
    end
    add_index :decidim_bih_report_evidence_items, [:report_id, :checksum], unique: true, name: 'report_evidence_identity'
    create_table :decidim_bih_report_dispatch_evidence do |t|
      t.references :dispatch, null: false, foreign_key: { to_table: :decidim_bih_report_dispatches }
      t.references :evidence_item, null: false, foreign_key: { to_table: :decidim_bih_report_evidence_items }
      t.references :request_source, polymorphic: true, index: { name: "idx_report_dispatch_evidence_request_source_81b8d2" }
      t.timestamps
    end
    add_index :decidim_bih_report_dispatch_evidence, [:evidence_item_id, :request_source_type, :request_source_id, :dispatch_id], unique: true, name: 'dispatch_evidence_request_identity'
    create_table :decidim_bih_report_evidence_shares do |t|
      t.references :evidence_item, null: false, foreign_key: { to_table: :decidim_bih_report_evidence_items }
      t.references :dispatch, null: false, foreign_key: { to_table: :decidim_bih_report_dispatches }
      t.references :request_source, polymorphic: true, index: { name: "idx_report_evidence_shares_request_source_2c39a2" }
      t.string :recipient_digest, null: false
      t.string :token_digest, null: false
      t.text :token_ciphertext, null: false
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.datetime :last_accessed_at
      t.integer :access_count, null: false, default: 0
      t.timestamps
    end
    add_index :decidim_bih_report_evidence_shares, :token_digest, unique: true
    add_index :decidim_bih_report_evidence_shares, [:evidence_item_id, :request_source_type, :request_source_id, :recipient_digest], unique: true, name: "prepared_service_evidence_share_identity"
  end
end
