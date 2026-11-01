# frozen_string_literal: true

class AddReportReviewProposals < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_report_review_proposals do |t|
      t.references :report, null: false, foreign_key: { to_table: :decidim_bih_reports }
      t.string :input_digest, null: false
      t.string :prompt_version, null: false
      t.string :state, null: false, default: "generating"
      t.string :model
      t.string :error_code
      t.text :proposal_ciphertext
      t.datetime :finished_at
      t.references :decided_by, foreign_key: { to_table: :decidim_users }
      t.datetime :decided_at
      t.string :approved_action
      t.jsonb :changed_fields, null: false, default: []
      t.timestamps
      t.index [:report_id, :input_digest, :prompt_version], unique: true, name: :idx_bih_review_proposal_version
      t.index [:state, :created_at], name: :idx_bih_review_proposal_pending
    end
  end
end
