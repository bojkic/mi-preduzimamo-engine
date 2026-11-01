# frozen_string_literal: true

# A citizen's logged volunteer hours against an opportunity. Starts "pending";
# an org admin verifies it, which awards goodwill points (hours x the schedule's
# volunteer_hour value) exactly once.
class CreateDecidimBihVolunteerLogs < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_volunteer_logs do |t|
      t.references :decidim_organization,
                   null: false,
                   index: true,
                   foreign_key: { to_table: :decidim_organizations }

      t.references :decidim_bih_volunteer_opportunity,
                   null: false,
                   index: { name: "idx_bih_volunteer_logs_on_opportunity" },
                   foreign_key: { to_table: :decidim_bih_volunteer_opportunities }

      t.references :decidim_user,
                   null: false,
                   index: { name: "idx_bih_volunteer_logs_on_user" },
                   foreign_key: { to_table: :decidim_users }

      t.integer :hours, null: false
      # pending | approved | rejected
      t.string :status, null: false, default: "pending"

      t.references :verified_by,
                   null: true,
                   index: { name: "idx_bih_volunteer_logs_on_verifier" },
                   foreign_key: { to_table: :decidim_users }
      t.datetime :verified_at

      t.timestamps
    end

    add_index :decidim_bih_volunteer_logs,
              [:decidim_organization_id, :status],
              name: "idx_bih_volunteer_logs_on_org_and_status"
  end
end
