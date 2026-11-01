# frozen_string_literal: true
module Decidim
  module Bih
    module Goodwill
      class SourceCreditCorrectionJob < Decidim::ApplicationJob
        queue_as :goodwill
        retry_on ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout, wait: :polynomially_longer, attempts: 5
        def perform(intent_id)
          intent = CorrectionIntent.find_by(id: intent_id)
          return unless intent && !intent.processed_at

          if intent.report_event.event_type == "report_created"
            report = intent.report
            if report.author
              EarningRules.new(organization: report.organization).award(report.author, :report,
                idempotency_key: IdempotencyKey.report(report.id), metadata: { occurred_at: report.created_at.iso8601 })
            end
            # The original submission has an immutable source key/time; a retry
            # reads the current moderation target but can never claim a later cap.
            SourceCreditCorrection.call(report:)
            intent.update!(processed_at: Time.current)
            return
          end

          # A stale intent never applies its old outcome. The latest committed
          # report event has its own durable intent, including after a restart.
          unless SourceCreditCorrection.outcome_version_for(intent.report.reload) == intent.decision_version
            intent.update!(processed_at: Time.current)
            return
          end
          ids = ReportEntitlement.family_ids(intent.report)
          Report.where(organization: intent.report.organization, id: ids).find_each do |report|
            SourceCreditCorrection.call(report:, actor: intent.report_event.actor)
          end
          ReportCorroboration.where(organization: intent.report.organization)
            .where("report_id IN (:ids) OR original_report_id IN (:ids)", ids:).find_each do |corroboration|
            SourceCreditCorrection.for_corroboration(corroboration, actor: intent.report_event.actor)
          end
          intent.update!(processed_at: Time.current)
        end
      end
    end
  end
end
