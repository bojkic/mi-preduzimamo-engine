# frozen_string_literal: true

# A citizen's general volunteering interest/availability. This is separate from
# verified hours: registering availability is a lightweight onboarding action
# that earns a one-time goodwill award.
class CreateDecidimBihVolunteerAvailabilities < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_volunteer_availabilities do |t|
      t.references :decidim_organization,
                   null: false,
                   index: { name: "idx_bih_volunteer_avails_on_org" },
                   foreign_key: { to_table: :decidim_organizations }
      t.references :decidim_user,
                   null: false,
                   index: { name: "idx_bih_volunteer_avails_on_user" },
                   foreign_key: { to_table: :decidim_users }
      t.text :availability
      t.text :interests

      t.timestamps
    end

    add_index :decidim_bih_volunteer_availabilities,
              [:decidim_organization_id, :decidim_user_id],
              unique: true,
              name: "idx_bih_volunteer_avails_on_org_and_user"
  end
end
