# frozen_string_literal: true

class AddPrivateReportEvidenceOwnership < ActiveRecord::Migration[7.2]
  def up
    add_column :decidim_bih_report_evidence_items, :purged_at, :datetime
    add_column :decidim_bih_report_evidence_items, :source_blob_id, :bigint
    add_column :decidim_bih_report_evidence_items, :purge_descriptor_ciphertext, :text
    add_column :decidim_bih_report_evidence_items, :purge_completed_at, :datetime
    execute "UPDATE decidim_bih_report_evidence_items SET source_blob_id = blob_id"
    change_column_null :decidim_bih_report_evidence_items, :blob_id, true
    add_check_constraint :decidim_bih_report_evidence_items,
                         "(purged_at IS NULL AND blob_id IS NOT NULL) OR (purged_at IS NOT NULL AND blob_id IS NULL)",
                         name: "report_evidence_live_blob_or_tombstone"
    remove_index :decidim_bih_report_evidence_items, name: "report_evidence_identity"
    add_index :decidim_bih_report_evidence_items, [:report_id, :checksum], unique: true,
                                                                           where: "purged_at IS NULL", name: "report_evidence_live_identity"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Purged evidence identities must survive alongside fresh uploads"
  end
end
