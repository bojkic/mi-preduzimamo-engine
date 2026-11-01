# frozen_string_literal: true

class AddReportSecondReminders < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_reports, :removed_from_public_at, :datetime
    add_index :decidim_bih_reports, :removed_from_public_at

    create_table :decidim_bih_report_second_reminders do |t|
      t.references :report, null: false, foreign_key: { to_table: :decidim_bih_reports }, index: { name: "idx_bih_second_reminder_report", unique: true }
      t.references :question, null: false, foreign_key: { to_table: :decidim_bih_report_messages }, index: { name: "idx_bih_second_reminder_question" }
      t.references :account_notification, null: false, foreign_key: { to_table: :decidim_bih_account_notifications }, index: { name: "idx_bih_second_reminder_notification" }
      t.datetime :delivered_at
      t.datetime :response_due_at
      t.datetime :closed_at
      t.string :outcome, null: false, default: "pending"
      t.timestamps
    end
  end
end
