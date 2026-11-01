# frozen_string_literal: true

# Adds structured volunteering data while keeping legacy free-text fields.
# Existing availability/location/category text remains readable; new submissions
# can be matched by area, precise time window, category and selected skills.
class AddStructuredVolunteeringFields < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_volunteer_availabilities,
               :area_scope,
               :string,
               null: false,
               default: "city"
    add_reference :decidim_bih_volunteer_availabilities,
                  :local_area,
                  null: true,
                  index: { name: "idx_bih_volunteer_avails_on_area" },
                  foreign_key: { to_table: :decidim_bih_local_areas, name: "fk_bih_volunteer_avails_area" }
    add_column :decidim_bih_volunteer_availabilities,
               :availability_windows,
               :jsonb,
               null: false,
               default: []
    add_column :decidim_bih_volunteer_availabilities,
               :interest_keys,
               :jsonb,
               null: false,
               default: []
    add_column :decidim_bih_volunteer_availabilities,
               :skill_keys,
               :jsonb,
               null: false,
               default: []
    add_column :decidim_bih_volunteer_availabilities,
               :capability_keys,
               :jsonb,
               null: false,
               default: []

    add_reference :decidim_bih_volunteer_opportunities,
                  :komsiluk,
                  null: true,
                  index: { name: "idx_bih_volunteer_opps_on_komsiluk" },
                  foreign_key: { to_table: :decidim_bih_local_areas, name: "fk_bih_volunteer_opps_komsiluk" }
    add_column :decidim_bih_volunteer_opportunities, :meeting_point, :string
    add_column :decidim_bih_volunteer_opportunities, :ends_at, :datetime
    add_column :decidim_bih_volunteer_opportunities, :signup_deadline_at, :datetime
    add_column :decidim_bih_volunteer_opportunities, :requirements, :text
    add_column :decidim_bih_volunteer_opportunities,
               :skill_keys,
               :jsonb,
               null: false,
               default: []
    add_column :decidim_bih_volunteer_opportunities,
               :capability_keys,
               :jsonb,
               null: false,
               default: []

    add_index :decidim_bih_volunteer_opportunities,
              [:decidim_organization_id, :komsiluk_id],
              name: "idx_bih_volunteer_opps_org_komsiluk"
    add_index :decidim_bih_volunteer_opportunities,
              [:decidim_organization_id, :category, :starts_at],
              name: "idx_bih_volunteer_opps_org_category_start"
  end
end
