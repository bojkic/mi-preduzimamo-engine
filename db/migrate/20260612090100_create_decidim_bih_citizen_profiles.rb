# frozen_string_literal: true

# Private per-citizen komšiluk assignment.
# NEVER rendered on the public profile, never written to extended_data,
# never exposed in the Decidim admin user-show. Lazy-created on first assignment.
#
# on_delete: :nullify on the user FK so deleting a Decidim user never blocks
# (the row is retained for analytics; komsiluk_id/mz_id nullable to survive).
class CreateDecidimBihCitizenProfiles < ActiveRecord::Migration[7.2]
  def up
    create_table :decidim_bih_citizen_profiles do |t|
      t.references :decidim_organization,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_organizations }

      # The citizen who self-assigned a komšiluk. Nullable so cascading user
      # deletion (nullify) leaves the row intact for historical area counts.
      t.bigint :decidim_user_id

      # Resolved komšiluk (level-1 area). Nullable — a newly inserted profile
      # that has been "touched" before the citizen finishes selecting.
      t.bigint :komsiluk_id

      # Denormalised parent MZ — fast query without the join on notification fan-out.
      t.bigint :mz_id

      # How the komšiluk was determined: "map", "address", "dropdown", "postal".
      t.string :source

      # When this assignment was made / last updated.
      t.datetime :assigned_at

      t.timestamps
    end

    # Unique profile per citizen per tenant.
    add_index :decidim_bih_citizen_profiles,
              [:decidim_organization_id, :decidim_user_id],
              unique: true,
              name: "idx_bih_citizen_profiles_on_org_and_user"

    # Fan-out: who is in a given komšiluk?
    add_index :decidim_bih_citizen_profiles,
              [:decidim_organization_id, :komsiluk_id],
              name: "idx_bih_citizen_profiles_on_org_and_komsiluk"

    # Fan-out: who is in a given MZ?
    add_index :decidim_bih_citizen_profiles,
              [:decidim_organization_id, :mz_id],
              name: "idx_bih_citizen_profiles_on_org_and_mz"

    # Sibling-convention FK: user nullable; on_delete :nullify.
    add_foreign_key :decidim_bih_citizen_profiles,
                    :decidim_users,
                    column: :decidim_user_id,
                    on_delete: :nullify,
                    name: "fk_bih_citizen_profiles_user"

    add_foreign_key :decidim_bih_citizen_profiles,
                    :decidim_bih_local_areas,
                    column: :komsiluk_id,
                    name: "fk_bih_citizen_profiles_komsiluk"

    add_foreign_key :decidim_bih_citizen_profiles,
                    :decidim_bih_local_areas,
                    column: :mz_id,
                    name: "fk_bih_citizen_profiles_mz"
  end

  def down
    drop_table :decidim_bih_citizen_profiles
  end
end
