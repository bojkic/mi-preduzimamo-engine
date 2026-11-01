# frozen_string_literal: true

# Volunteer RSVP / sign-up: a signed-in citizen registers intent to attend an
# opportunity. Capacity is enforced against the count of GOING signups; the
# unique [opportunity, user] index keeps re-signups idempotent (one row per
# citizen per opportunity, toggled going/cancelled).
class CreateDecidimBihVolunteerSignups < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_volunteer_signups do |t|
      t.references :decidim_organization,
                   null: false,
                   index: { name: "idx_bih_volunteer_signups_on_org" },
                   foreign_key: { to_table: :decidim_organizations }
      t.references :decidim_bih_volunteer_opportunity,
                   null: false,
                   index: { name: "idx_bih_volunteer_signups_on_opportunity" },
                   foreign_key: { to_table: :decidim_bih_volunteer_opportunities }
      t.references :decidim_user,
                   null: false,
                   index: { name: "idx_bih_volunteer_signups_on_user" },
                   foreign_key: { to_table: :decidim_users }
      t.string :status, null: false, default: "going"

      t.timestamps
    end

    add_index :decidim_bih_volunteer_signups,
              [:decidim_bih_volunteer_opportunity_id, :decidim_user_id],
              unique: true,
              name: "idx_bih_volunteer_signups_on_opportunity_and_user"
  end
end
