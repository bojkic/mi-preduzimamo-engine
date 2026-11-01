# frozen_string_literal: true

class AddGoodwillSourceAccounting < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_goodwill_credit_corrections do |t|
      t.bigint :decidim_organization_id, null: false
      t.bigint :account_id, null: false
      t.string :source_key, null: false
      t.string :decision_version, null: false
      t.string :rule_version, null: false, default: "2026-09-outcomes-v1"
      t.bigint :original_transaction_id, null: false
      t.bigint :actor_id
      t.integer :previous_target, null: false
      t.integer :target_amount, null: false
      t.integer :recognition_delta, null: false
      t.datetime :earned_at, null: false
      t.string :reason, null: false
      t.jsonb :metadata, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :decidim_bih_goodwill_credit_corrections, [:decidim_organization_id, :source_key, :decision_version], unique: true, name: "idx_goodwill_correction_source_version"
    add_index :decidim_bih_goodwill_credit_corrections, [:account_id, :earned_at], name: "idx_goodwill_correction_account_period"
    add_foreign_key :decidim_bih_goodwill_credit_corrections, :decidim_bih_goodwill_accounts, column: :account_id
    add_foreign_key :decidim_bih_goodwill_credit_corrections, :decidim_bih_goodwill_transactions, column: :original_transaction_id
    add_check_constraint :decidim_bih_goodwill_credit_corrections, "target_amount >= 0 AND previous_target >= 0 AND recognition_delta = target_amount - previous_target", name: "chk_goodwill_correction_delta"

    create_table :decidim_bih_goodwill_credit_settlements do |t|
      t.bigint :credit_correction_id, null: false
      t.string :status, null: false, default: "pending"
      t.integer :wallet_delta, null: false, default: 0
      t.bigint :transaction_id
      t.bigint :settled_by_id
      t.datetime :notified_at
      t.timestamps
    end
    add_index :decidim_bih_goodwill_credit_settlements, :credit_correction_id, unique: true, name: "idx_goodwill_settlement_correction"
    add_foreign_key :decidim_bih_goodwill_credit_settlements, :decidim_bih_goodwill_credit_corrections, column: :credit_correction_id
    add_foreign_key :decidim_bih_goodwill_credit_settlements, :decidim_bih_goodwill_transactions, column: :transaction_id

    create_table :decidim_bih_goodwill_award_admissions do |t|
      t.bigint :decidim_organization_id, null: false
      t.bigint :account_id, null: false
      t.string :source_key, null: false
      t.string :action, null: false
      t.string :period, null: false, default: "day"
      t.date :period_start, null: false
      t.datetime :occurred_at, null: false
      t.string :outcome, null: false
      t.integer :amount, null: false, default: 0
      t.bigint :transaction_id
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :decidim_bih_goodwill_award_admissions, [:decidim_organization_id, :source_key], unique: true, name: "idx_goodwill_admission_source"
    add_index :decidim_bih_goodwill_award_admissions, [:account_id, :action, :period_start, :outcome], name: "idx_goodwill_admission_allowance"
    add_foreign_key :decidim_bih_goodwill_award_admissions, :decidim_bih_goodwill_accounts, column: :account_id
    add_foreign_key :decidim_bih_goodwill_award_admissions, :decidim_bih_goodwill_transactions, column: :transaction_id

    create_table :decidim_bih_report_corroborations do |t|
      t.bigint :decidim_organization_id, null: false
      t.bigint :decidim_user_id, null: false
      t.bigint :report_id, null: false
      t.bigint :original_report_id, null: false
      t.timestamps
    end
    add_index :decidim_bih_report_corroborations, [:decidim_organization_id, :decidim_user_id, :report_id], unique: true, name: "idx_bih_corroboration_actor_problem"
    add_foreign_key :decidim_bih_report_corroborations, :decidim_bih_reports, column: :report_id
    add_foreign_key :decidim_bih_report_corroborations, :decidim_users, column: :decidim_user_id
    add_foreign_key :decidim_bih_report_corroborations, :decidim_bih_reports, column: :original_report_id

    create_table :decidim_bih_goodwill_correction_intents do |t|
      t.bigint :report_event_id, null: false
      t.string :decision_version, null: false
      t.integer :target_amount, null: false
      t.bigint :report_id, null: false
      t.datetime :processed_at
      t.timestamps
    end
    add_index :decidim_bih_goodwill_correction_intents, :report_event_id, unique: true, name: "idx_goodwill_correction_intent_event"
    add_foreign_key :decidim_bih_goodwill_correction_intents, :decidim_bih_report_events, column: :report_event_id
    add_foreign_key :decidim_bih_goodwill_correction_intents, :decidim_bih_reports, column: :report_id

    add_column :decidim_bih_goodwill_referrals, :pending_reason, :string
    add_column :decidim_bih_goodwill_referrals, :next_attempt_at, :datetime
    add_column :decidim_bih_goodwill_referrals, :transaction_id, :bigint
    add_index :decidim_bih_goodwill_referrals, [:status, :next_attempt_at], name: "idx_goodwill_referral_due"
    add_foreign_key :decidim_bih_goodwill_referrals, :decidim_bih_goodwill_transactions, column: :transaction_id
    [:decidim_bih_goodwill_credit_corrections, :decidim_bih_goodwill_award_admissions,
     :decidim_bih_report_corroborations].each do |table|
      add_foreign_key table, :decidim_organizations, column: :decidim_organization_id
    end
    add_foreign_key :decidim_bih_goodwill_credit_corrections, :decidim_users, column: :actor_id
    add_foreign_key :decidim_bih_goodwill_credit_settlements, :decidim_users, column: :settled_by_id
    add_check_constraint :decidim_bih_goodwill_credit_settlements,
      "status IN ('pending','settled','admin_pending','superseded')", name: "chk_goodwill_settlement_status"
    add_check_constraint :decidim_bih_goodwill_award_admissions,
      "amount >= 0 AND period IN ('day','month') AND outcome IN ('awarded','capped','disabled','ineligible','duplicate')",
      name: "chk_goodwill_admission_outcome"
  end
end
