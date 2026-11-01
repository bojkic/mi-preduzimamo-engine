# frozen_string_literal: true

class AddCancellationToVolunteerOpportunities < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_volunteer_opportunities, :cancelled_at, :datetime
    add_column :decidim_bih_volunteer_opportunities, :cancellation_reason, :text
    add_reference :decidim_bih_volunteer_opportunities,
                  :cancelled_by,
                  foreign_key: { to_table: :decidim_users },
                  index: { name: "idx_bih_volunteer_opps_cancelled_by" }

    add_index :decidim_bih_volunteer_opportunities,
              [:decidim_organization_id, :cancelled_at],
              name: "idx_bih_volunteer_opps_org_cancelled"
  end
end
