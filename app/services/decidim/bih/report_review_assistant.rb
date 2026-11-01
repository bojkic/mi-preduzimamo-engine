# frozen_string_literal: true

module Decidim
  module Bih
    # Deduplicated background suggestions. Configuration and model failures leave
    # the human workflow available; no generated value mutates a report.
    class ReportReviewAssistant
      def self.active?(organization)
        case_agent_mode(organization) != "off"
      end

      # R3 is shadow-only. Activation and sealed-evaluation receipts ship later.
      def self.case_agent_mode(organization)
        configured = Setting.namespace_for(organization, "report_review")["case_agent"].to_s
        %w(shadow on).include?(configured) ? "shadow" : "off"
      end

      def self.eligible?(report)
        (case_agent_mode(report.organization) == "shadow" || report.review_state == "pending") && !ReportWorkQueue.closed?(report) &&
          !report.dispatches.exists?(state: %w(queued sending unknown))
      end

      def self.enqueue(report, trigger: nil)
        return unless active?(report.organization) && eligible?(report)

        ActiveRecord.after_all_transactions_commit do
          if trigger.is_a?(InboundEmail)
            ReportReviewProposalJob.perform_later(report.id, inbound_email_id: trigger.id)
          else
            ReportReviewProposalJob.perform_later(report.id)
          end
        rescue StandardError => e
          Rails.logger.warn("[ReportReviewAssistant] enqueue pending report=#{report.id} error=#{e.class}")
        end
      rescue StandardError => e
        Rails.logger.warn("[ReportReviewAssistant] enqueue pending report=#{report.id} error=#{e.class}")
      end

      # Retain the job/sweep contract; every execution rechecks current settings.
      # The agent prepares an editable proposal and never executes its action.
      def call(report, retry_failed: false, trigger: nil, shadow_only: false, lease_owner: nil, recover_stale: false) # rubocop:disable Lint/UnusedMethodArgument, Metrics/ParameterLists -- preserve serialized job and sweep API; lease identity
        return unless self.class.active?(report.organization) && self.class.eligible?(report)

        Ai::CaseAgent.new(report, trigger:, retry_failed:, lease_owner:, recover_stale:).call[:proposal]
      end
    end
  end
end
