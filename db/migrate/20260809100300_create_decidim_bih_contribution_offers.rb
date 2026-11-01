# frozen_string_literal: true

# A citizen or verified partner profile can offer a quantity against an
# approved non-cash need. The row stores workflow facts only: no contact details,
# beneficiary evidence or employee/member roster data.
class CreateDecidimBihContributionOffers < ActiveRecord::Migration[7.2]
  ACTIVE_STATUSES_SQL = "status IN ('offered', 'accepted', 'delivered', 'confirmed')"

  def change
    create_table :decidim_bih_contribution_offers do |t|
      t.references :decidim_organization,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_organizations }
      t.references :contribution_need,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_bih_contribution_needs, on_delete: :restrict }
      t.references :decidim_user,
                   null: true,
                   index: { name: "idx_bih_contribution_offers_user" },
                   foreign_key: { to_table: :decidim_users, on_delete: :nullify }
      t.references :partner_profile,
                   null: true,
                   index: { name: "idx_bih_contribution_offers_profile" },
                   foreign_key: { to_table: :decidim_bih_partner_profiles, on_delete: :restrict }
      t.references :accepted_by,
                   null: true,
                   index: { name: "idx_bih_contribution_offers_accepted_by" },
                   foreign_key: { to_table: :decidim_users, on_delete: :nullify }
      t.references :declined_by,
                   null: true,
                   index: { name: "idx_bih_contribution_offers_declined_by" },
                   foreign_key: { to_table: :decidim_users, on_delete: :nullify }
      t.references :confirmed_by,
                   null: true,
                   index: { name: "idx_bih_contribution_offers_confirmed_by" },
                   foreign_key: { to_table: :decidim_users, on_delete: :nullify }
      t.references :recognized_by,
                   null: true,
                   index: { name: "idx_bih_contribution_offers_recognized_by" },
                   foreign_key: { to_table: :decidim_users, on_delete: :nullify }

      t.decimal :quantity, precision: 12, scale: 2, null: false
      t.string :status, null: false, default: "offered"
      t.text :decline_reason
      t.datetime :accepted_at
      t.datetime :declined_at
      t.datetime :withdrawn_at
      t.datetime :delivered_at
      t.datetime :confirmed_at
      t.datetime :recognized_at
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_index :decidim_bih_contribution_offers,
              [:decidim_organization_id, :status, :created_at],
              name: "idx_bih_contribution_offers_queue"
    add_index :decidim_bih_contribution_offers,
              [:contribution_need_id, :status],
              name: "idx_bih_contribution_offers_need_status"
    add_index :decidim_bih_contribution_offers,
              [:contribution_need_id, :decidim_user_id],
              unique: true,
              where: "partner_profile_id IS NULL AND #{ACTIVE_STATUSES_SQL}",
              name: "idx_bih_contribution_offers_active_user"
    add_index :decidim_bih_contribution_offers,
              [:contribution_need_id, :partner_profile_id],
              unique: true,
              where: "partner_profile_id IS NOT NULL AND #{ACTIVE_STATUSES_SQL}",
              name: "idx_bih_contribution_offers_active_profile"
  end
end
