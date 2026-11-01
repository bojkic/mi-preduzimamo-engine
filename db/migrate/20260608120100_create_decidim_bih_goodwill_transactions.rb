# frozen_string_literal: true

# A goodwill transaction groups a balanced (sum-zero) set of ledger entries and
# carries the business kind. Append-only: corrections are made by posting a new
# reversing transaction, never by editing this one.
class CreateDecidimBihGoodwillTransactions < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_goodwill_transactions do |t|
      t.references :decidim_organization,
                   null: false,
                   index: true,
                   foreign_key: { to_table: :decidim_organizations }

      # earn | gift | regrant | redeem | adjustment
      t.string :kind, null: false

      # Free-form reason tag, e.g. "proposal", "comment", "like",
      # "volunteer_hour", "referral", or "reversal_of:<id>".
      t.string :reason

      # Idempotency / audit. Lets a subscriber avoid double-awarding for the same
      # source event (e.g. "comment:1234"); unique per organization when present.
      t.string :idempotency_key

      # JSON context (action, source resource gid, actor id, reversal pointer).
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :decidim_bih_goodwill_transactions, :kind
    add_index :decidim_bih_goodwill_transactions,
              [:decidim_organization_id, :idempotency_key],
              unique: true,
              where: "idempotency_key IS NOT NULL",
              name: "idx_bih_goodwill_txns_on_org_and_idemkey"
  end
end
