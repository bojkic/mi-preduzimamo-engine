# frozen_string_literal: true

# Operator-reviewed organization spending requests. Public organization admins
# can request point movement or reward sponsorship; operators/admins decide.
# The immutable Goodwill ledger records actual point movement only on approval.
class CreateDecidimBihOrgSpendingRequests < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_org_spending_requests do |t|
      t.references :decidim_organization,
                   null: false,
                   foreign_key: { to_table: :decidim_organizations },
                   index: { name: "idx_bih_org_spending_org" }
      t.references :source_partner_profile,
                   null: false,
                   foreign_key: { to_table: :decidim_bih_partner_profiles },
                   index: { name: "idx_bih_org_spending_source" }
      t.references :target_partner_profile,
                   foreign_key: { to_table: :decidim_bih_partner_profiles },
                   index: { name: "idx_bih_org_spending_target" }
      t.references :requested_by,
                   foreign_key: { to_table: :decidim_users },
                   index: { name: "idx_bih_org_spending_requested_by" }
      t.references :decided_by,
                   foreign_key: { to_table: :decidim_users },
                   index: { name: "idx_bih_org_spending_decided_by" }

      t.string :request_type, null: false
      t.string :status, null: false, default: "pending"
      t.integer :points, null: false
      t.string :category, null: false
      t.string :reward_title
      t.text :reward_description
      t.integer :reward_stock
      t.integer :reward_cost
      t.datetime :decided_at
      t.text :rejection_reason
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :decidim_bih_org_spending_requests,
              [:decidim_organization_id, :status, :request_type],
              name: "idx_bih_org_spending_queue"

    add_reference :decidim_bih_goodwill_rewards,
                  :sponsor_partner_profile,
                  foreign_key: { to_table: :decidim_bih_partner_profiles },
                  index: { name: "idx_bih_rewards_sponsor_profile" }
  end
end
