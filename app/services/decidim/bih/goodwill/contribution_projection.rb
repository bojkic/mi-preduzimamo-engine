# frozen_string_literal: true
module Decidim
  module Bih
    module Goodwill
      # One SQL definition for cached totals, windows and source-period streaks.
      module ContributionProjection
        module_function
        def sql
          reasons = Transaction::CONTRIBUTION_ADJUSTMENT_REASONS.map { |reason| Account.connection.quote(reason) }.join(",")
          <<~SQL
            SELECT e.decidim_bih_goodwill_account_id AS account_id, COALESCE(t.metadata->>'reverses_transaction_id',t.id::text) AS source_key,
                   e.amount AS amount, COALESCE(NULLIF(original.metadata->>'occurred_at', '')::timestamptz, original.created_at AT TIME ZONE 'UTC', NULLIF(t.metadata->>'occurred_at', '')::timestamptz, t.created_at AT TIME ZONE 'UTC') AS earned_at
            FROM decidim_bih_goodwill_entries e
            JOIN decidim_bih_goodwill_transactions t ON t.id=e.decidim_bih_goodwill_transaction_id
            LEFT JOIN decidim_bih_goodwill_transactions original ON original.id::text=t.metadata->>'reverses_transaction_id' AND original.decidim_organization_id=t.decidim_organization_id
            WHERE (t.kind='earn' AND e.amount>0)
               OR (t.kind='adjustment' AND t.reason IN (#{reasons}))
            UNION ALL
            SELECT account_id, original_transaction_id::text AS source_key, recognition_delta AS amount,
                   earned_at AT TIME ZONE 'UTC' AS earned_at
            FROM decidim_bih_goodwill_credit_corrections
          SQL
        end
        def score(account, since: nil)
          return 0 unless account&.kind == "user"
          filter = since ? " AND earned_at >= #{Account.connection.quote(boundary(since))}" : ""
          Account.connection.select_value("SELECT COALESCE(SUM(amount),0) FROM (#{sql}) contributions WHERE account_id=#{Integer(account.id)}#{filter}").to_i
        end
        def boundary(value)
          if value.is_a?(Date) && !value.is_a?(DateTime)
            Time.find_zone!("Europe/Sarajevo").local(value.year, value.month, value.day)
          else
            value
          end
        end
        def active_weeks(account)
          return [] unless account&.kind == "user"
          query = <<~SQL
            SELECT DISTINCT DATE_TRUNC('week', earned_at AT TIME ZONE 'Europe/Sarajevo')::date AS week
            FROM (SELECT source_key, MIN(earned_at) AS earned_at, SUM(amount) AS amount
                  FROM (#{sql}) contributions WHERE account_id=#{Integer(account.id)} GROUP BY source_key) valid_sources
            WHERE amount > 0
          SQL
          Account.connection.select_values(query).map { |day| day.is_a?(Date) ? day : Date.parse(day) }
        end
        def refresh!(account)
          account.update_columns(cached_contribution: score(account))
          after_commit(account)
        end
        def after_commit(account)
          ActiveRecord.after_all_transactions_commit do
            owner = account.reload.owner
            if owner.is_a?(Decidim::User) && !owner.group?
              Decidim::Gamification.set_score(owner, :goodwill_contributor, account.contribution_score)
              Decidim::Bih::PublicRecognition.invalidate_leaderboard_cache(owner)
            end
          rescue StandardError => e
            Rails.logger.error("[goodwill] projection refresh failed: #{e.class}")
          end
        end
      end
    end
  end
end
