# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Wallet movements retain posting month. Recognition corrections are also
      # shown in the original contribution month, separately from wallet totals.
      # Positive and negative flows are classified before netting a kind.
      class MonthlyStatement
        def initialize(account)
          @account = account
        end

        def months
          return [] unless @account&.persisted?

          rows = Hash.new { |hash, month| hash[month] = { month:, by_kind: Hash.new(0), by_category: Hash.new(0), recognition_adjustment: 0 } }
          grouped_entries.each do |(month, kind, reason, positive), amount|
            row = rows[month.to_date]
            row[:by_kind][kind] += amount
            row[:by_category][category(kind, reason, positive)] += amount
          end
          CreditCorrection.where(account: @account).group(Arel.sql(bucket("earned_at"))).sum(:recognition_delta).each do |month, amount|
            rows[month.to_date][:recognition_adjustment] += amount
          end
          running = 0
          rows.keys.sort.map do |month|
            row = rows.fetch(month)
            net = row[:by_kind].values.sum
            running += net
            row.merge(earned: row[:by_category]["earned"], spent: row[:by_category]["spent"], net:, running_balance: running)
          end.reverse
        end

        private

        def bucket(column)
          "DATE_TRUNC('month', (#{column} AT TIME ZONE 'UTC') AT TIME ZONE 'Europe/Sarajevo')::date"
        end

        def grouped_entries
          @account.entries.joins(:ledger_transaction)
                  .group(Arel.sql(bucket("decidim_bih_goodwill_transactions.created_at")),
                         "decidim_bih_goodwill_transactions.kind", "decidim_bih_goodwill_transactions.reason",
                         Arel.sql("decidim_bih_goodwill_entries.amount > 0"))
                  .sum("decidim_bih_goodwill_entries.amount")
        end

        def category(kind, reason, positive)
          return positive ? "earned" : "corrections" if kind == "earn"
          return positive ? "received" : "given" if %w(gift regrant).include?(kind)
          return positive ? "refunds" : "spent" if kind == "redeem"
          if kind == "adjustment" && reason.to_s.start_with?("reversal_of:")
            original = Transaction.where(organization: @account.organization).find_by(id: reason.delete_prefix("reversal_of:"))
            return positive ? "refunds" : "recoveries" if original&.kind == "redeem"
            return "recoveries" if %w(gift regrant).include?(original&.kind)
          end
          "corrections"
        end
      end
    end
  end
end
