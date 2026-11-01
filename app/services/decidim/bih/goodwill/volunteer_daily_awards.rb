# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Runs under the volunteer user's row lock. The DB uniqueness and ledger
      # key are a second line of defense against concurrent verifications.
      module VolunteerDailyAwards
        module_function

        def award_for(log, ledger: Ledger.new, earning_rules: nil, award_model: VolunteerDailyAward)
          return nil unless log.work_date
          return nil if log.user.respond_to?(:group?) && log.user.group?

          scope = award_model.where(organization: log.organization, user: log.user, work_date: log.work_date)
          row = scope.first
          return nil if row&.active?

          version = row ? row.version + 1 : 1
          rules = earning_rules || EarningRules.new(organization: log.organization)
          transaction = ledger.award(
            log.user,
            rules.points_for(:volunteer_day),
            reason: "volunteer_day",
            idempotency_key: daily_key(log, version),
            metadata: { volunteer_log_id: log.id, work_date: log.work_date.iso8601, hours: log.hours }
          )
          return nil unless transaction

          if row
            row.update!(active: true, version:, transaction_id: transaction.id)
          else
            award_model.create!(
              organization: log.organization, user: log.user, work_date: log.work_date,
              active: true, version:, transaction_id: transaction.id
            )
          end
          transaction
        end

        def reverse_if_unsupported(log, ledger: Ledger.new)
          return nil unless log.work_date
          return nil if VolunteerLog.approved.where(organization: log.organization, user: log.user,
                                                   work_date: log.work_date).exists?

          row = VolunteerDailyAward.find_by(organization: log.organization, user: log.user, work_date: log.work_date)
          return nil unless row&.active?

          transaction = Transaction.find(row.transaction_id)
          reversal = ledger.reverse(transaction, contribution: true)
          correction = CreditCorrection.where(original_transaction_id: transaction.id, target_amount: 0).order(:id).last
          if reversal || correction
            row.update!(active: false)
            # Core gamification supports a targeted reset from the same cached
            # contribution figure its global reset uses. Keep the displayed
            # badge in step with the append-only ledger correction.
            account = Account.find_by(
              organization: log.organization,
              owner_type: log.user.class.base_class.name,
              owner_id: log.user.id,
              kind: "user"
            )
            ContributionProjection.after_commit(account) if account
          end
          reversal
        end

        def daily_key(log, version)
          base = IdempotencyKey.volunteer_day(log.user.id, log.work_date)
          version == 1 ? base : "#{base}:v#{version}"
        end
      end
    end
  end
end
