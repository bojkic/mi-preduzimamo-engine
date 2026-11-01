# frozen_string_literal: true

# Verified-referral attribution: links the citizen who invited (referrer) to the
# one who joined (invitee). One referral per invitee. The referrer is rewarded
# only once the invitee VERIFIES (status pending -> rewarded), server-side.
class CreateDecidimBihGoodwillReferrals < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_goodwill_referrals do |t|
      t.references :decidim_organization,
                   null: false,
                   index: true,
                   foreign_key: { to_table: :decidim_organizations }

      t.references :referrer,
                   null: false,
                   index: { name: "idx_bih_goodwill_referrals_on_referrer" },
                   foreign_key: { to_table: :decidim_users }

      t.references :invitee,
                   null: false,
                   index: { name: "idx_bih_goodwill_referrals_on_invitee", unique: true },
                   foreign_key: { to_table: :decidim_users }

      # pending | rewarded
      t.string :status, null: false, default: "pending"
      t.datetime :rewarded_at

      t.timestamps
    end
  end
end
