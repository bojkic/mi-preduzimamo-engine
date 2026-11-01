# frozen_string_literal: true

# One goodwill ledger account per owner per organization, plus a single
# owner-less "system" issuance account per organization (the double-entry
# counterparty for every "earn").
class CreateDecidimBihGoodwillAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_goodwill_accounts do |t|
      t.references :decidim_organization,
                   null: false,
                   index: true,
                   foreign_key: { to_table: :decidim_organizations }

      # Polymorphic owner. Citizens AND groups are Decidim::User rows in 0.31.5
      # (a group is a User with extended_data["group"]=true), but polymorphic
      # keeps the ledger reusable for future owner types. The system/issuance
      # account has a NULL owner and kind="system".
      t.string :owner_type, null: true
      t.bigint :owner_id, null: true

      # "user" (a citizen/group wallet) or "system" (the issuance counterparty).
      t.string :kind, null: false, default: "user"

      t.timestamps
    end

    add_index :decidim_bih_goodwill_accounts,
              [:owner_type, :owner_id],
              name: "idx_bih_goodwill_accounts_on_owner"

    # One account per owner per organization.
    add_index :decidim_bih_goodwill_accounts,
              [:decidim_organization_id, :owner_type, :owner_id],
              unique: true,
              name: "idx_bih_goodwill_accounts_on_org_and_owner"

    # Exactly one system account per organization (Postgres treats the NULL
    # owner rows as distinct, so a partial unique index is required).
    add_index :decidim_bih_goodwill_accounts,
              :decidim_organization_id,
              unique: true,
              where: "kind = 'system'",
              name: "idx_bih_goodwill_accounts_one_system_per_org"
  end
end
