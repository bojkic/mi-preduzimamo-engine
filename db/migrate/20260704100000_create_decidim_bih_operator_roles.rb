# frozen_string_literal: true

# Capability-scoped BIH operator roles.
#
# V1 roles are organization-wide within the current Decidim tenant: the role
# grants only the allowlisted actions in OperatorAuthorization, with no extra
# MZ/profile/process scope. Every role expires unless renewed and can be revoked
# without deleting the historical row.
class CreateDecidimBihOperatorRoles < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_operator_roles do |t|
      t.references :decidim_organization,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_organizations }
      t.references :decidim_user,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_users }
      t.string :role, null: false
      t.references :created_by,
                   null: true,
                   index: { name: "idx_bih_operator_roles_created_by" },
                   foreign_key: { to_table: :decidim_users }
      t.datetime :expires_at, null: false
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :decidim_bih_operator_roles,
              [:decidim_organization_id, :decidim_user_id, :role, :revoked_at],
              name: "idx_bih_operator_roles_org_user_role"
    add_index :decidim_bih_operator_roles,
              [:decidim_organization_id, :role, :expires_at],
              name: "idx_bih_operator_roles_org_role_expiry"
  end
end
