# frozen_string_literal: true

# Additive, query-shaped indexes for public report list/map, Goodwill
# dashboards/leaderboards, and volunteer review queues.
class AddPerformanceIndexesToDecidimBihTables < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def up
    add_report_indexes
    add_goodwill_indexes
    add_volunteer_indexes
  end

  def down
    remove_indexes(:decidim_bih_volunteer_opportunities, "idx_bih_volunteer_opps_org_active_created")
    remove_indexes(:decidim_bih_volunteer_logs, "idx_bih_volunteer_logs_org_user_created", "idx_bih_volunteer_logs_org_status_created")
    remove_indexes(:decidim_bih_goodwill_referrals, "idx_bih_goodwill_referrals_org_status_rewarded")
    remove_indexes(:decidim_bih_goodwill_match_requests, "idx_bih_goodwill_match_requests_org_status_created")
    remove_indexes(:decidim_bih_goodwill_transactions, "idx_bih_goodwill_txns_org_kind_created")
    remove_indexes(:decidim_bih_goodwill_entries, "idx_bih_goodwill_entries_org_account_created_amt")
    remove_indexes(:decidim_bih_goodwill_accounts, "idx_bih_goodwill_accounts_org_contribution_rank")
    remove_indexes(:decidim_bih_reports, "idx_bih_reports_org_located_created", "idx_bih_reports_org_created", "idx_bih_reports_org_status_category_created")
  end

  private

  def add_report_indexes
    add_index :decidim_bih_reports,
              [:decidim_organization_id, :status, :category, :created_at, :id],
              order: { created_at: :desc, id: :desc },
              name: "idx_bih_reports_org_status_category_created",
              algorithm: :concurrently,
              if_not_exists: true

    add_index :decidim_bih_reports,
              [:decidim_organization_id, :created_at, :id],
              order: { created_at: :desc, id: :desc },
              name: "idx_bih_reports_org_created",
              algorithm: :concurrently,
              if_not_exists: true

    add_index :decidim_bih_reports,
              [:decidim_organization_id, :created_at, :id],
              order: { created_at: :desc, id: :desc },
              where: "latitude IS NOT NULL AND longitude IS NOT NULL",
              name: "idx_bih_reports_org_located_created",
              algorithm: :concurrently,
              if_not_exists: true
  end

  def add_goodwill_indexes
    add_index :decidim_bih_goodwill_accounts,
              [:decidim_organization_id, :cached_contribution, :id],
              order: { cached_contribution: :desc, id: :asc },
              where: "kind = 'user' AND cached_contribution > 0",
              name: "idx_bih_goodwill_accounts_org_contribution_rank",
              algorithm: :concurrently,
              if_not_exists: true

    add_index :decidim_bih_goodwill_entries,
              [:decidim_organization_id, :decidim_bih_goodwill_account_id, :created_at],
              include: [:amount, :decidim_bih_goodwill_transaction_id],
              where: "amount > 0",
              name: "idx_bih_goodwill_entries_org_account_created_amt",
              algorithm: :concurrently,
              if_not_exists: true

    add_index :decidim_bih_goodwill_transactions,
              [:decidim_organization_id, :kind, :created_at, :id],
              order: { created_at: :desc, id: :desc },
              name: "idx_bih_goodwill_txns_org_kind_created",
              algorithm: :concurrently,
              if_not_exists: true

    add_index :decidim_bih_goodwill_match_requests,
              [:decidim_organization_id, :status, :created_at, :id],
              name: "idx_bih_goodwill_match_requests_org_status_created",
              algorithm: :concurrently,
              if_not_exists: true

    add_index :decidim_bih_goodwill_referrals,
              [:decidim_organization_id, :status, :rewarded_at, :referrer_id],
              name: "idx_bih_goodwill_referrals_org_status_rewarded",
              algorithm: :concurrently,
              if_not_exists: true
  end

  def add_volunteer_indexes
    add_index :decidim_bih_volunteer_logs,
              [:decidim_organization_id, :status, :created_at, :id],
              name: "idx_bih_volunteer_logs_org_status_created",
              algorithm: :concurrently,
              if_not_exists: true

    add_index :decidim_bih_volunteer_logs,
              [:decidim_organization_id, :decidim_user_id, :created_at, :id],
              order: { created_at: :desc, id: :desc },
              name: "idx_bih_volunteer_logs_org_user_created",
              algorithm: :concurrently,
              if_not_exists: true

    add_index :decidim_bih_volunteer_opportunities,
              [:decidim_organization_id, :active, :created_at, :id],
              order: { created_at: :desc, id: :desc },
              name: "idx_bih_volunteer_opps_org_active_created",
              algorithm: :concurrently,
              if_not_exists: true
  end

  def remove_indexes(table, *names)
    names.each do |name|
      remove_index table, name:, algorithm: :concurrently, if_exists: true
    end
  end
end
