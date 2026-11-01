# frozen_string_literal: true

# Public actions share the existing volunteer proposal/review/signup/hour-log
# pipeline, but can carry organization-funded bonus rules. Bonus payouts are
# ledger transfers from the verified organization wallet to the verified citizen
# after the logged hours are approved.
class AddPublicActionAndOrgBonusToVolunteerOpportunities < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_volunteer_opportunities,
               :opportunity_kind,
               :string,
               null: false,
               default: "volunteer"
    add_column :decidim_bih_volunteer_opportunities,
               :org_bonus_points_per_hour,
               :integer,
               null: false,
               default: 0
    add_column :decidim_bih_volunteer_opportunities,
               :org_bonus_budget_cap,
               :integer
    add_column :decidim_bih_volunteer_opportunities,
               :org_bonus_max_participants,
               :integer
    add_column :decidim_bih_volunteer_opportunities,
               :org_bonus_awarded_points,
               :integer,
               null: false,
               default: 0
    add_column :decidim_bih_volunteer_opportunities,
               :org_bonus_recognition,
               :string

    add_index :decidim_bih_volunteer_opportunities,
              [:decidim_organization_id, :opportunity_kind],
              name: "idx_bih_volunteer_opps_org_kind"
  end
end
