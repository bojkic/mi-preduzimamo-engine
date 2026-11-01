# frozen_string_literal: true

# Records that a given Viber sender has proven control of a phone number via an
# OTP. This linkage is INTENTIONALLY decoupled from Decidim::User: verifying an
# OTP proves phone control for attributing the sender's civic reports
# (reporter_phone), and must NEVER be joined to or used to authenticate an
# existing Decidim account (account-takeover risk).
class CreateDecidimBihViberLinkages < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_viber_linkages do |t|
      t.references :decidim_organization,
                   null: false,
                   index: true,
                   foreign_key: { to_table: :decidim_organizations }

      t.string :viber_sender, null: false
      t.string :phone, null: false
      t.datetime :verified_at

      t.timestamps
    end

    # One linkage per (organization, Viber sender): a sender controls at most one
    # verified phone at a time; re-verifying a new phone updates the same row.
    add_index :decidim_bih_viber_linkages,
              [:decidim_organization_id, :viber_sender],
              unique: true,
              name: "idx_bih_viber_linkages_on_org_and_sender"
  end
end
