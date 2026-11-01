# frozen_string_literal: true

class CreateGoodwillVolunteerBonusCommitments < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_volunteer_bonus_commitments do |t|
      t.bigint :decidim_organization_id, null: false
      t.bigint :volunteer_log_id, null: false
      t.bigint :volunteer_opportunity_id, null: false
      t.bigint :decidim_user_id, null: false
      t.integer :requested_points, null: false
      t.integer :paid_points, null: false, default: 0
      t.integer :installments, null: false, default: 0
      t.string :status, null: false, default: "payable"
      t.datetime :last_attempt_at
      t.jsonb :events, null: false, default: []
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :decidim_bih_volunteer_bonus_commitments, :volunteer_log_id, unique: true, name: "idx_bih_bonus_commitment_log"
    add_index :decidim_bih_volunteer_bonus_commitments, [:decidim_organization_id, :volunteer_opportunity_id], name: "idx_bih_bonus_commitment_opportunity"
    add_foreign_key :decidim_bih_volunteer_bonus_commitments, :decidim_organizations, column: :decidim_organization_id
    add_foreign_key :decidim_bih_volunteer_bonus_commitments, :decidim_bih_volunteer_logs, column: :volunteer_log_id
    add_foreign_key :decidim_bih_volunteer_bonus_commitments, :decidim_bih_volunteer_opportunities, column: :volunteer_opportunity_id
    add_foreign_key :decidim_bih_volunteer_bonus_commitments, :decidim_users, column: :decidim_user_id
    add_check_constraint :decidim_bih_volunteer_bonus_commitments,
      "requested_points >= 0 AND paid_points >= 0 AND paid_points <= requested_points AND installments >= 0", name: "bih_bonus_commitment_amounts"
  end
end
