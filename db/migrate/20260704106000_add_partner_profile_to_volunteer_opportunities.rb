# frozen_string_literal: true

# Optional organization actor for volunteer opportunity proposals.
#
# Public submissions still require the existing operator/admin approval before
# publishing. When present, partner_profile_id records that a real user proposed
# the opportunity while acting for a verified organization.
class AddPartnerProfileToVolunteerOpportunities < ActiveRecord::Migration[7.2]
  def change
    add_reference :decidim_bih_volunteer_opportunities,
                  :partner_profile,
                  null: true,
                  index: { name: "idx_bih_volunteer_opps_partner_profile" },
                  foreign_key: { to_table: :decidim_bih_partner_profiles }
  end
end
