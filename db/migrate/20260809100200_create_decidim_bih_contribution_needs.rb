# frozen_string_literal: true

# Moderated, non-cash requests from verified partner profiles. People and
# specialist-skill requests stay in VolunteerOpportunity; money stays on native
# Budget projects through ProjectDonationLink.
class CreateDecidimBihContributionNeeds < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_contribution_needs do |t|
      t.references :decidim_organization,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_organizations }
      t.references :partner_profile,
                   null: false,
                   index: { name: "idx_bih_contribution_needs_profile" },
                   foreign_key: { to_table: :decidim_bih_partner_profiles, on_delete: :restrict }
      t.references :decidim_author,
                   null: true,
                   index: { name: "idx_bih_contribution_needs_author" },
                   foreign_key: { to_table: :decidim_users, on_delete: :nullify }
      t.references :reviewed_by,
                   null: true,
                   index: { name: "idx_bih_contribution_needs_reviewer" },
                   foreign_key: { to_table: :decidim_users, on_delete: :nullify }
      t.references :decidim_budgets_project,
                   null: true,
                   index: { name: "idx_bih_contribution_needs_project" },
                   foreign_key: { to_table: :decidim_budgets_projects, on_delete: :nullify }

      t.string :need_type, null: false
      t.string :title, null: false
      t.text :description, null: false
      t.decimal :quantity, precision: 12, scale: 2, null: false
      t.string :unit, null: false
      t.date :needed_by
      t.string :location
      t.string :review_status, null: false, default: "pending"
      t.string :fulfillment_status, null: false, default: "open"
      t.datetime :reviewed_at
      t.datetime :published_at
      t.datetime :closed_at
      t.text :rejection_reason
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_index :decidim_bih_contribution_needs,
              [:decidim_organization_id, :review_status, :fulfillment_status, :created_at],
              name: "idx_bih_contribution_needs_public_queue"
    add_index :decidim_bih_contribution_needs,
              [:partner_profile_id, :review_status, :fulfillment_status],
              name: "idx_bih_contribution_needs_profile_status"
  end
end
