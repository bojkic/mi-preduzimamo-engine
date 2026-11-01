# frozen_string_literal: true

# First-class local organization profiles ("Organizacije").
#
# These are not Decidim tenants and not logins. Real Decidim users act on behalf
# of these profiles through PartnerMembership rows. Existing Decidim user groups
# are linked through legacy_user_group_id for compatibility during migration.
class CreateDecidimBihPartnerProfiles < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_partner_profiles do |t|
      t.references :decidim_organization,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_organizations }
      t.string :display_name, null: false
      t.string :legal_name
      t.string :slug, null: false
      t.string :kind, null: false
      t.string :verification_status, null: false, default: "draft"
      t.text :public_description
      t.string :logo
      t.string :website
      t.bigint :local_area_id
      t.string :private_contact_name
      t.string :private_contact_email
      t.string :private_contact_phone
      t.references :verified_by,
                   null: true,
                   index: { name: "idx_bih_partner_profiles_verified_by" },
                   foreign_key: { to_table: :decidim_users }
      t.datetime :verified_at
      t.datetime :rejected_at
      t.string :rejection_reason
      t.bigint :legacy_user_group_id
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :decidim_bih_partner_profiles,
              [:decidim_organization_id, :slug],
              unique: true,
              name: "idx_bih_partner_profiles_org_slug"
    add_index :decidim_bih_partner_profiles,
              [:decidim_organization_id, :verification_status, :kind],
              name: "idx_bih_partner_profiles_org_status_kind"
    add_index :decidim_bih_partner_profiles,
              [:decidim_organization_id, :legacy_user_group_id],
              unique: true,
              where: "legacy_user_group_id IS NOT NULL",
              name: "idx_bih_partner_profiles_legacy_group"

    add_foreign_key :decidim_bih_partner_profiles,
                    :decidim_bih_local_areas,
                    column: :local_area_id,
                    name: "fk_bih_partner_profiles_local_area"
    add_foreign_key :decidim_bih_partner_profiles,
                    :decidim_users,
                    column: :legacy_user_group_id,
                    on_delete: :nullify,
                    name: "fk_bih_partner_profiles_legacy_group"
  end
end
