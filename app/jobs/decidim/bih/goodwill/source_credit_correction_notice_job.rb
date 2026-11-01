# frozen_string_literal: true
module Decidim
  module Bih
    module Goodwill
      class SourceCreditCorrectionNoticeJob < Decidim::ApplicationJob
        queue_as :goodwill
        retry_on ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout, wait: :polynomially_longer, attempts: 5
        def perform(correction_id)
          correction = CreditCorrection.find(correction_id)
          settlement = correction.settlement
          settlement.with_lock do
            return if settlement.notified_at
            owner = correction.account.owner
            if (correction.recognition_delta != 0 || settlement.ledger_transaction) && owner.is_a?(Decidim::User) && !owner.deleted?
              prior_pending = Decidim::Notification.where(user: owner, event_class: CreditCorrectedEvent.name)
                .where("extra->>'correction_id' = ? AND extra->>'phase' = ?", correction.id.to_s, "recognition_pending").exists?
              phase = if settlement.status == "admin_pending"
                        "recognition_pending"
                      elsif prior_pending || correction.recognition_delta.zero?
                        "wallet_settled"
                      else
                        "recognition_settled"
                      end
              report = SourceCreditCorrection.source_report(correction.original_transaction)
              extra = { correction_id: correction.id, old_points: correction.previous_target, new_points: correction.target_amount,
                delta: correction.recognition_delta, status: settlement.status, phase:, wallet_delta: settlement.wallet_delta, report_reference: report&.reference,
                old_level: correction.metadata["level_before"], new_level: correction.metadata["level_after"] }
              # Bell creation and receipt marker commit atomically. This avoids
              # an asynchronous fan-out enqueued twice if this worker rolls back.
              Decidim::NotificationGeneratorForRecipient.new("decidim.events.bih.goodwill.credit_corrected",
                CreditCorrectedEvent, owner, owner, "affected_user", extra).generate
            end
            settlement.update!(notified_at: Time.current)
          end
        end
      end
    end
  end
end
