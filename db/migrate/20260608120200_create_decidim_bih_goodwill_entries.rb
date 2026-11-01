# frozen_string_literal: true

# A single signed posting (positive=credit, negative=debit) belonging to one
# transaction and one account. Append-only at the model layer; the sum across a
# transaction's entries is always zero (double-entry invariant).
class CreateDecidimBihGoodwillEntries < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_goodwill_entries do |t|
      t.references :decidim_organization,
                   null: false,
                   index: true,
                   foreign_key: { to_table: :decidim_organizations }

      t.references :decidim_bih_goodwill_transaction,
                   null: false,
                   index: { name: "idx_bih_goodwill_entries_on_txn" },
                   foreign_key: { to_table: :decidim_bih_goodwill_transactions }

      t.references :decidim_bih_goodwill_account,
                   null: false,
                   index: { name: "idx_bih_goodwill_entries_on_account" },
                   foreign_key: { to_table: :decidim_bih_goodwill_accounts }

      # Signed integer points: positive = credit, negative = debit.
      t.integer :amount, null: false

      t.timestamps
    end

    add_index :decidim_bih_goodwill_entries,
              [:decidim_bih_goodwill_account_id, :created_at],
              name: "idx_bih_goodwill_entries_on_account_and_created"
  end
end
