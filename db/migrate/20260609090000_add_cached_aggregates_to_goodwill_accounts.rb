# frozen_string_literal: true

# Cache the two ledger aggregates on the account row so profile renders and the
# leaderboard stop recomputing JOIN+SUM scans over every lifetime entry. The
# columns are maintained incrementally inside Ledger#build_and_save (append-only
# ledger ⇒ a periodic reconcile rake can verify them drift-free).
class AddCachedAggregatesToGoodwillAccounts < ActiveRecord::Migration[7.2]
  def up
    add_column :decidim_bih_goodwill_accounts, :cached_balance, :bigint, null: false, default: 0
    add_column :decidim_bih_goodwill_accounts, :cached_contribution, :bigint, null: false, default: 0

    # Index-backed top-N leaderboard (no JOIN/GROUP/SUM).
    add_index :decidim_bih_goodwill_accounts,
              [:decidim_organization_id, :cached_contribution],
              where: "kind = 'user'",
              name: "idx_bih_goodwill_accounts_leaderboard"

    # Covers the per-award daily-cap lookup (org, kind, reason, created_at).
    add_index :decidim_bih_goodwill_transactions,
              [:decidim_organization_id, :kind, :reason, :created_at],
              name: "idx_bih_goodwill_txns_cap_lookup"

    # Backfill from the immutable ledger.
    execute(<<~SQL.squish)
      UPDATE decidim_bih_goodwill_accounts a
      SET cached_balance = COALESCE(
        (SELECT SUM(e.amount) FROM decidim_bih_goodwill_entries e
         WHERE e.decidim_bih_goodwill_account_id = a.id), 0)
    SQL
    execute(<<~SQL.squish)
      UPDATE decidim_bih_goodwill_accounts a
      SET cached_contribution = COALESCE(
        (SELECT SUM(e.amount) FROM decidim_bih_goodwill_entries e
         JOIN decidim_bih_goodwill_transactions t ON t.id = e.decidim_bih_goodwill_transaction_id
         WHERE e.decidim_bih_goodwill_account_id = a.id AND t.kind = 'earn' AND e.amount > 0), 0)
    SQL
  end

  def down
    remove_index :decidim_bih_goodwill_transactions, name: "idx_bih_goodwill_txns_cap_lookup"
    remove_index :decidim_bih_goodwill_accounts, name: "idx_bih_goodwill_accounts_leaderboard"
    remove_column :decidim_bih_goodwill_accounts, :cached_contribution
    remove_column :decidim_bih_goodwill_accounts, :cached_balance
  end
end
