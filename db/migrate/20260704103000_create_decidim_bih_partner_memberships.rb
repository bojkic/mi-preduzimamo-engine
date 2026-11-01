# frozen_string_literal: true

# Visible organization membership rows for PartnerProfile.
#
# Owner decision for v1: accepted members are public for transparency and there
# is no member opt-out. Private contact fields stay on the profile, not here.
class CreateDecidimBihPartnerMemberships < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_partner_memberships do |t|
      t.references :decidim_organization,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_organizations }
      t.references :partner_profile,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_bih_partner_profiles }
      t.references :decidim_user,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_users }
      t.string :role, null: false
      t.string :status, null: false, default: "accepted"
      t.references :invited_by,
                   null: true,
                   index: { name: "idx_bih_partner_members_invited_by" },
                   foreign_key: { to_table: :decidim_users }
      t.datetime :accepted_at
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :decidim_bih_partner_memberships,
              [:partner_profile_id, :decidim_user_id],
              unique: true,
              name: "idx_bih_partner_members_profile_user"
    add_index :decidim_bih_partner_memberships,
              [:decidim_organization_id, :decidim_user_id, :status],
              name: "idx_bih_partner_members_org_user_status"
    add_index :decidim_bih_partner_memberships,
              [:partner_profile_id, :role, :status],
              name: "idx_bih_partner_members_profile_role_status"
  end
end
