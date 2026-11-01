# frozen_string_literal: true

# Citizen-proposed volunteer opportunities must be reviewed by an administrator
# before they become public and before points are awarded to the proposer.
class AddReviewToDecidimBihVolunteerOpportunities < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_volunteer_opportunities,
               :review_status,
               :string,
               null: false,
               default: "approved"
    add_reference :decidim_bih_volunteer_opportunities,
                  :reviewed_by,
                  null: true,
                  index: { name: "idx_bih_volunteer_opps_on_reviewer" },
                  foreign_key: { to_table: :decidim_users }
    add_column :decidim_bih_volunteer_opportunities, :reviewed_at, :datetime

    add_index :decidim_bih_volunteer_opportunities,
              [:decidim_organization_id, :review_status],
              name: "idx_bih_volunteer_opps_on_org_and_review_status"
  end
end
