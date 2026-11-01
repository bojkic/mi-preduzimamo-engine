# frozen_string_literal: true

# Adds lightweight recurrence metadata and partner confirmation markers to
# volunteer opportunities. Each generated shift remains a normal opportunity,
# so RSVP, waitlist, and hour verification behavior stay unchanged.
class AddSeriesAndPartnerConfirmationToVolunteerOpportunities < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_volunteer_opportunities, :series_key, :string
    add_column :decidim_bih_volunteer_opportunities, :series_position, :integer
    add_column :decidim_bih_volunteer_opportunities, :series_total, :integer
    add_column :decidim_bih_volunteer_opportunities, :partner_name, :string
    add_column :decidim_bih_volunteer_opportunities, :partner_confirmed_at, :datetime

    add_reference :decidim_bih_volunteer_opportunities,
                  :partner_confirmed_by,
                  null: true,
                  index: { name: "idx_bih_volunteer_opps_on_partner_confirmer" },
                  foreign_key: { to_table: :decidim_users }

    add_index :decidim_bih_volunteer_opportunities,
              [:decidim_organization_id, :series_key],
              name: "idx_bih_volunteer_opps_on_org_and_series"
  end
end
