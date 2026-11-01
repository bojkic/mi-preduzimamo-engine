# frozen_string_literal: true

class AddReportCaseWorkflow < ActiveRecord::Migration[7.2]
  def change
    change_table :decidim_bih_reports do |t|
      t.string :review_state, null: false, default: "pending"
      t.bigint :reviewed_by_id
      t.datetime :reviewed_at
      t.bigint :assigned_to_id
      t.datetime :response_due_at
      t.text :forwarding_note
      t.string :forwarding_recipient
      t.string :external_submission_reference
      t.text :resolution_evidence
      t.string :resident_feedback
      t.datetime :reminded_due_at
    end
    add_foreign_key :decidim_bih_reports, :decidim_users, column: :reviewed_by_id
    add_foreign_key :decidim_bih_reports, :decidim_users, column: :assigned_to_id
    add_index :decidim_bih_reports, [:decidim_organization_id, :response_due_at], name: :idx_bih_reports_case_due
    create_table :decidim_bih_report_messages do |t|
      t.references :report, null: false, foreign_key: { to_table: :decidim_bih_reports }
      t.references :actor, foreign_key: { to_table: :decidim_users }
      t.references :account_notification, foreign_key: { to_table: :decidim_bih_account_notifications, on_delete: :nullify }
      t.string :actor_role, null: false
      t.string :kind, null: false
      t.text :body, null: false
      t.string :notification_state, null: false, default: "pending"
      t.datetime :notified_at
      t.datetime :read_at
      t.timestamps
    end
  end
end
