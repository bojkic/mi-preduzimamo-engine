# frozen_string_literal: true

class CreateDecidimBihReportReplyCapabilities < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_report_reply_capabilities do |t|
      t.references :decidim_organization, null: false, foreign_key: true, index: { name: "idx_report_reply_capabilities_decidim_organiz_36b3be" }
      t.references :decidim_bih_report, null: false, foreign_key: true, index: { name: "idx_report_reply_capabilities_decidim_bih_rep_e2f09b" }
      t.string :audience, null: false
      t.text :correspondent_digests, array: true, default: [], null: false
      t.text :token_ciphertext, null: false
      t.string :token_digest, null: false
      t.references :question_message, foreign_key: { to_table: :decidim_bih_report_messages }, index: { name: "idx_report_reply_capabilities_question_messag_261b14" }
      t.datetime :revoked_at
      t.datetime :last_used_at
      t.timestamps
    end
    add_index :decidim_bih_report_reply_capabilities, :token_digest, unique: true
    add_index :decidim_bih_report_reply_capabilities,
              "decidim_bih_report_id, audience, correspondent_digests, COALESCE(question_message_id, 0)",
              unique: true, where: "revoked_at IS NULL", name: "idx_bih_reply_capabilities_active"
    add_check_constraint :decidim_bih_report_reply_capabilities, "audience IN ('service','citizen')", name: "bih_reply_capability_audience"
  end
end
