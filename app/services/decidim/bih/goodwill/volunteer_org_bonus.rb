# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Approval-order wallet transfers. No funds are reserved at signup; a
      # participant slot is consumed by the first payment to a distinct person.
      # A durable per-log amount and installment keys allow explicit finance
      # retries without re-awarding base points or repaying a reversed claim.
      class VolunteerOrgBonus
        REASON = "volunteer_org_bonus"

        def self.call(log)
          new(log).call
        end

        def self.retry(log, actor:, reason:)
          return nil unless log && actor && actor.organization == log.organization && reason.to_s.strip.present? && reason.to_s.length <= 1_000
          return nil unless OperatorAuthorization.allowed?(actor, :organization_spending_decide,
                                                            organization: log.organization, resource: log.opportunity)
          ActiveRecord::Base.transaction do
            payer = new(log)
            result = log.rejected? ? payer.revoke!(actor:, reason:) : payer.call(actor:, reason:)
            OperatorAuditEvent.record!(organization: log.organization, actor:, event_type: "volunteer_bonus_retried",
              permission: "organization_spending_decide", resource: log, metadata: { reason_present: true })
            result
          end
        end

        def initialize(log)
          @log = log
          @opportunity = log&.opportunity
        end

        def call(actor: nil, reason: nil)
          return nil unless eligible?

          ActiveRecord::Base.transaction do
            opportunity.lock!
            log.lock!
            next nil unless eligible?

            claim = commitment!
            claim.lock!
            refresh_awarded_points!
            if claim.reversed_payment? || %w(reversed admin_pending).include?(claim.status)
              claim.record!("reversed", actor:, reason: "previous_payment_reversed") unless claim.status == "admin_pending"
              next nil
            end
            already_paid = claim.current_paid_points
            if already_paid >= claim.requested_points
              claim.record!("paid", actor:, reason:, paid: already_paid) unless claim.status == "paid"
              next claim.active_payments.order(:id).last
            end
            if challenge_limit_reached?
              claim.record!("participant_limit", actor:, reason:)
              next nil
            end

            ledger = Ledger.new
            from_owner = PartnerOwner.owner_for(opportunity.partner_profile)
            from_account = ledger.account_for(from_owner)
            to_account = ledger.account_for(log.user)
            AccountLocks.lock!(from_account, to_account)
            # A generic finance reversal can race with the pre-lock read.
            # Recheck under wallet locks before paying another installment.
            if claim.reversed_payment?
              claim.record!("reversed", actor:, reason: "previous_payment_reversed")
              next nil
            end
            budget = opportunity.org_bonus_remaining_points
            owed = claim.requested_points - already_paid
            amount = [capped_amount(owed), from_account.reload.balance].min
            unless amount.positive?
              state = budget && budget <= 0 ? "budget_exhausted" : "unfunded"
              claim.record!(already_paid.positive? ? "partially_paid" : state, actor:, reason: state)
              next nil
            end

            claim.installments += 1
            key = IdempotencyKey.volunteer_org_bonus(log.id)
            key = "#{key}:installment:#{claim.installments}" if claim.installments > 1
            transaction = ledger.transfer(from_owner:, to_owner: log.user, amount:, kind: "regrant", reason: REASON,
              idempotency_key: key, metadata: metadata(amount, claim))
            next nil unless transaction

            opportunity.update!(org_bonus_awarded_points: opportunity.org_bonus_awarded_points.to_i + amount)
            paid = already_paid + amount
            claim.record!(paid >= claim.requested_points ? "paid" : "partially_paid", actor:, reason:, transaction:, paid:)
            transaction
          end
        end

        # Correction reverses all installments together. If the recipient has
        # spent the bonus, retain a review state instead of creating debt.
        def revoke!(actor:, reason:)
          return nil unless log && opportunity

          ActiveRecord::Base.transaction do
            opportunity.lock!
            log.lock!
            claim = commitment!(only_existing: true)
            next nil unless claim
            claim.lock!
            active = claim.active_payments.order(:id).to_a
            begin
              ActiveRecord::Base.transaction(requires_new: true) do
                AccountLocks.lock!(*active.flat_map { |payment| payment.entries.map(&:account) }) if active.any?
                active.each { |payment| Ledger.new.reverse(payment, actor:) }
              end
            rescue InsufficientBalanceError
              claim.record!("admin_pending", actor:, reason:)
              next claim
            end
            refresh_awarded_points!
            claim.record!("reversed", actor:, reason:, paid: 0)
            claim
          end
        end

        private

        attr_reader :log, :opportunity

        def eligible?
          log&.approved? && opportunity&.org_bonus_enabled? && log.user.present? && log.hours.to_d.positive?
        end

        def commitment!(only_existing: false)
          claim = VolunteerBonusCommitment.find_by(organization: log.organization, log:)
          return claim if claim
          prior = Transaction.where(organization: log.organization, reason: REASON)
            .where("metadata ->> 'volunteer_log_id' = ? OR idempotency_key = ?", log.id.to_s, IdempotencyKey.volunteer_org_bonus(log.id)).order(:id).to_a
          return nil if only_existing && prior.empty?
          requested = prior.first&.metadata&.fetch("requested_amount", nil) || requested_amount
          VolunteerBonusCommitment.create!(organization: log.organization, log:, opportunity:, user: log.user,
            requested_points: [requested.to_i, prior.sum(&:credited_amount)].max, installments: prior.size, status: "payable")
        end

        def capped_amount(requested = requested_amount)
          remaining = opportunity.org_bonus_remaining_points
          remaining.nil? ? requested : [requested, remaining].min
        end

        def refresh_awarded_points!
          paid = bonus_transactions.sum("(metadata ->> 'awarded_amount')::integer")
          opportunity.update!(org_bonus_awarded_points: paid) if opportunity.org_bonus_awarded_points != paid
        end

        def challenge_limit_reached?
          limit = opportunity.org_bonus_max_participants.to_i
          return false unless limit.positive?
          admitted_ids = bonus_transactions.distinct.pluck(Arel.sql("metadata ->> 'user_id'"))
          return false if admitted_ids.include?(log.user.id.to_s)

          admitted_ids.size >= limit
        end

        def bonus_transactions
          Transaction.where(organization: log.organization, reason: REASON)
            .where("metadata ->> 'volunteer_opportunity_id' = ?", opportunity.id.to_s)
            .where("NOT EXISTS (SELECT 1 FROM decidim_bih_goodwill_transactions reversals " \
                   "WHERE reversals.decidim_organization_id = decidim_bih_goodwill_transactions.decidim_organization_id " \
                   "AND reversals.idempotency_key = 'reversal_of:' || decidim_bih_goodwill_transactions.id::text)")
        end

        def metadata(amount, claim)
          { partner_profile_id: opportunity.partner_profile_id, volunteer_opportunity_id: opportunity.id,
            volunteer_log_id: log.id, user_id: log.user.id, hours: log.hours,
            points_per_hour: opportunity.org_bonus_points_per_hour, requested_amount: claim.requested_points,
            awarded_amount: amount, commitment_id: claim.id, installment: claim.installments,
            opportunity_kind: opportunity.opportunity_kind, recognition: opportunity.org_bonus_recognition }.compact
        end

        def requested_amount
          (opportunity.org_bonus_points_per_hour.to_d * log.hours.to_d).round(0, BigDecimal::ROUND_HALF_UP).to_i
        end
      end
    end
  end
end
