# frozen_string_literal: true

# Canonical organization-scoped mapping from a native Decidim Budgets project
# to the host donation-provider campaign key. Provider URLs and credentials stay
# host-owned and are deliberately not stored here.
class CreateDecidimBihProjectDonationLinks < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_project_donation_links do |t|
      t.references :decidim_organization,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_organizations }
      t.references :decidim_budgets_project,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_budgets_projects, on_delete: :restrict }
      t.string :campaign_key, null: false
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :decidim_bih_project_donation_links,
              [:decidim_organization_id, :decidim_budgets_project_id],
              unique: true,
              name: "idx_bih_project_donation_links_project"
    add_index :decidim_bih_project_donation_links,
              [:decidim_organization_id, :campaign_key],
              unique: true,
              name: "idx_bih_project_donation_links_campaign"
    add_index :decidim_bih_project_donation_links,
              [:decidim_organization_id, :active],
              name: "idx_bih_project_donation_links_active"
  end
end
