# frozen_string_literal: true

# Volunteer opportunities ("missions") an organization publishes for citizens to
# sign up and log hours against. Org-scoped; created by org admins.
class CreateDecidimBihVolunteerOpportunities < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_volunteer_opportunities do |t|
      t.references :decidim_organization,
                   null: false,
                   index: true,
                   foreign_key: { to_table: :decidim_organizations }

      t.string :title, null: false
      t.text :description
      t.boolean :active, null: false, default: true

      # The admin who created it (nullable so a deleted admin doesn't cascade).
      t.references :decidim_author,
                   null: true,
                   index: { name: "idx_bih_volunteer_opps_on_author" },
                   foreign_key: { to_table: :decidim_users }

      t.timestamps
    end

    add_index :decidim_bih_volunteer_opportunities,
              [:decidim_organization_id, :active],
              name: "idx_bih_volunteer_opps_on_org_and_active"
  end
end
