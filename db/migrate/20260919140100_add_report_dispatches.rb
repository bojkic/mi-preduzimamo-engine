# frozen_string_literal: true

class AddReportDispatches < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_report_dispatches do |t|
      t.references :report, null: false, foreign_key: { to_table: :decidim_bih_reports }
      t.references :approved_by, null: false, foreign_key: { to_table: :decidim_users }
      t.string :kind, null: false
      t.string :state, null: false, default: "queued"
      t.string :input_digest, null: false
      t.string :deduplication_key, null: false
      t.text :snapshot_ciphertext, null: false
      t.string :message_id, null: false
      t.string :error_class
      t.datetime :started_at
      t.datetime :accepted_at
      t.datetime :reconciled_at
      t.references :reconciled_by, foreign_key: { to_table: :decidim_users }
      t.text :reconciliation_evidence
      t.timestamps
      t.index :deduplication_key, unique: true, name: :idx_bih_dispatch_identity
      t.index [:state, :created_at], name: :idx_bih_dispatch_pending
    end
  end
end
