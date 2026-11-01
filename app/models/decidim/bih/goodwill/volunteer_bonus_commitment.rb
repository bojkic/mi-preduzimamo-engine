# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # A recorded possible bonus, not a reservation of an organization's funds.
      # Its requested amount is fixed when approved work first reaches the payer.
      class VolunteerBonusCommitment < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_volunteer_bonus_commitments"
        STATUSES = %w(payable partially_paid unfunded paid participant_limit budget_exhausted reversed admin_pending).freeze

        belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
        belongs_to :log, class_name: "Decidim::Bih::VolunteerLog", foreign_key: :volunteer_log_id
        belongs_to :opportunity, class_name: "Decidim::Bih::VolunteerOpportunity", foreign_key: :volunteer_opportunity_id
        belongs_to :user, class_name: "Decidim::User", foreign_key: :decidim_user_id
        attr_readonly :decidim_organization_id, :volunteer_log_id, :volunteer_opportunity_id, :decidim_user_id, :requested_points
        validates :status, inclusion: { in: STATUSES }
        validates :requested_points, :paid_points, :installments, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
        validate :same_organization

        def payments
          Transaction.where(organization:, reason: VolunteerOrgBonus::REASON)
            .where("metadata ->> 'volunteer_log_id' = ? OR idempotency_key = ?", log.id.to_s, IdempotencyKey.volunteer_org_bonus(log.id))
        end

        def active_payments
          payments.where("NOT EXISTS (SELECT 1 FROM decidim_bih_goodwill_transactions reversals " \
            "WHERE reversals.decidim_organization_id = decidim_bih_goodwill_transactions.decidim_organization_id " \
            "AND reversals.idempotency_key = 'reversal_of:' || decidim_bih_goodwill_transactions.id::text)")
        end

        def reversed_payment?
          payments.count != active_payments.count
        end

        def current_paid_points
          active_payments.sum("(metadata ->> 'awarded_amount')::integer")
        end

        def outstanding_points
          return 0 if effective_status == "reversed" || log.rejected?

          [requested_points - current_paid_points, 0].max
        end

        def effective_status
          return "reversed" if reversed_payment? && status != "admin_pending"

          status
        end

        def record!(state, actor: nil, reason: nil, transaction: nil, paid: current_paid_points)
          self.status = state
          self.paid_points = paid
          self.last_attempt_at = Time.current
          self.events = Array(events) + [{ "status" => state, "paid_points" => paid,
            "at" => last_attempt_at.iso8601(6), "actor_id" => actor&.id,
            "reason" => reason.to_s.presence, "transaction_id" => transaction&.id }.compact]
          save!
        end

        private

        def same_organization
          errors.add(:log, :invalid) unless log && log.organization == organization && log.opportunity == opportunity && log.user == user
        end
      end
    end
  end
end
