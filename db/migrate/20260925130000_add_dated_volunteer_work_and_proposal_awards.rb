# frozen_string_literal: true

class AddDatedVolunteerWorkAndProposalAwards < ActiveRecord::Migration[7.2]
  def up
    change_column :decidim_bih_volunteer_logs, :hours, :decimal, precision: 6, scale: 2, null: false
    add_column :decidim_bih_volunteer_logs, :work_date, :date
    add_column :decidim_bih_volunteer_logs, :worked_from_at, :datetime
    add_column :decidim_bih_volunteer_logs, :worked_until_at, :datetime
    add_column :decidim_bih_volunteer_opportunities, :proposal_identity, :string
    add_index :decidim_bih_volunteer_logs,
              [:decidim_organization_id, :decidim_user_id, :work_date],
              name: "idx_bih_volunteer_logs_on_user_work_date"
    add_check_constraint :decidim_bih_volunteer_logs,
                         "(worked_from_at IS NULL AND worked_until_at IS NULL) OR " \
                         "(work_date IS NOT NULL AND worked_from_at IS NOT NULL AND " \
                         "worked_until_at IS NOT NULL AND worked_until_at > worked_from_at)",
                         name: "chk_bih_volunteer_log_interval"
    execute <<~SQL
      UPDATE decidim_bih_volunteer_opportunities
      SET proposal_identity = CASE
        WHEN series_key IS NOT NULL AND series_key <> '' THEN 'series:' || series_key
        ELSE 'opportunity:' || id::text END
      WHERE proposal_identity IS NULL
    SQL

    create_table :decidim_bih_volunteer_proposal_awards do |t|
      t.references :decidim_organization, null: false,
                   foreign_key: { to_table: :decidim_organizations },
                   index: { name: "idx_bih_volunteer_proposal_awards_org" }
      t.string :proposal_identity, null: false
      t.bigint :first_opportunity_id, null: false
      t.bigint :legacy_transaction_id
      t.timestamps
    end
    add_index :decidim_bih_volunteer_proposal_awards,
              [:decidim_organization_id, :proposal_identity],
              unique: true, name: "idx_bih_volunteer_proposal_awards_unique"

    create_table :decidim_bih_volunteer_daily_awards do |t|
      t.references :decidim_organization, null: false,
                   foreign_key: { to_table: :decidim_organizations },
                   index: { name: "idx_bih_volunteer_daily_awards_org" }
      t.references :decidim_user, null: false,
                   foreign_key: { to_table: :decidim_users },
                   index: { name: "idx_bih_volunteer_daily_awards_user" }
      t.date :work_date, null: false
      t.boolean :active, null: false, default: true
      t.integer :version, null: false, default: 1
      t.bigint :transaction_id
      t.timestamps
    end
    add_index :decidim_bih_volunteer_daily_awards,
              [:decidim_organization_id, :decidim_user_id, :work_date],
              unique: true, name: "idx_bih_volunteer_daily_awards_unique"

    # Historic per-term credits already settled. A marker for each source
    # proposal prevents a grouped series from being credited again.
    execute <<~SQL
      INSERT INTO decidim_bih_volunteer_proposal_awards
        (decidim_organization_id, proposal_identity, first_opportunity_id,
         legacy_transaction_id, created_at, updated_at)
      SELECT o.decidim_organization_id,
             CASE WHEN o.series_key IS NOT NULL AND o.series_key <> ''
               THEN 'series:' || o.series_key
               ELSE 'opportunity:' || o.id::text END,
             MIN(o.id), MIN(tx.id), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM decidim_bih_volunteer_opportunities o
      JOIN decidim_bih_goodwill_transactions tx
        ON tx.decidim_organization_id = o.decidim_organization_id
       AND tx.idempotency_key = 'volunteer_opportunity:' || o.id::text
       AND tx.reason = 'volunteer_opportunity'
      GROUP BY o.decidim_organization_id,
               CASE WHEN o.series_key IS NOT NULL AND o.series_key <> ''
                 THEN 'series:' || o.series_key
                 ELSE 'opportunity:' || o.id::text END
      ON CONFLICT (decidim_organization_id, proposal_identity) DO NOTHING
    SQL
  end

  def down
    if select_value("SELECT 1 FROM decidim_bih_volunteer_logs WHERE hours <> trunc(hours) LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "fractional volunteer hours cannot be restored to integer"
    end

    drop_table :decidim_bih_volunteer_daily_awards
    drop_table :decidim_bih_volunteer_proposal_awards
    remove_check_constraint :decidim_bih_volunteer_logs, name: "chk_bih_volunteer_log_interval"
    remove_index :decidim_bih_volunteer_logs, name: "idx_bih_volunteer_logs_on_user_work_date"
    remove_column :decidim_bih_volunteer_logs, :worked_until_at
    remove_column :decidim_bih_volunteer_logs, :worked_from_at
    remove_column :decidim_bih_volunteer_logs, :work_date
    remove_column :decidim_bih_volunteer_opportunities, :proposal_identity
    change_column :decidim_bih_volunteer_logs, :hours, :integer, null: false
  end
end
