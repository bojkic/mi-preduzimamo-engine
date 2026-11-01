# frozen_string_literal: true

class AddPayoutFieldsToDecidimBihGoodwillMatchRequests < ActiveRecord::Migration[7.2]
  def change
    change_table :decidim_bih_goodwill_match_requests, bulk: true do |t|
      t.string :payout_status, null: false, default: "unpaid"
      t.integer :payout_amount_minor_units
      t.string :payout_currency, null: false, default: "BAM"
      t.string :payout_reference
      t.text :payout_note
      t.date :payout_paid_on
      t.datetime :payout_recorded_at
      t.references :payout_recorded_by,
                   null: true,
                   index: { name: "idx_bih_goodwill_match_requests_on_payout_by" },
                   foreign_key: { to_table: :decidim_users }
    end

    add_index :decidim_bih_goodwill_match_requests,
              [:decidim_organization_id, :payout_status, :updated_at, :id],
              name: "idx_bih_goodwill_match_requests_org_payout_updated"
  end
end
