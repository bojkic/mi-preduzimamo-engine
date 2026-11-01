# frozen_string_literal: true

module Decidim
  module Bih
    # Drains approvals queued by the retired preview. Those jobs lack an
    # approving actor and immutable snapshot, so they cannot be upgraded into
    # a ReportDispatch approval or sent under an inferred operator identity.
    class ReportCaseForwardJob < ApplicationJob
      queue_as :reports

      def perform(report_id, digest)
        report = Report.find_by(id: report_id)
        return unless report

        report.with_lock do
          next if report.forwarded_at || report.collective? || Report::TERMINAL_STATUSES.include?(report.status)
          next if report.dispatches.exists? || report.review_state != "validated"
          next unless ActiveSupport::SecurityUtils.secure_compare(ReportCaseWorkflow.digest(report), digest.to_s)

          report.update!(review_state: "pending", review_pending_since: Time.current, deadline_kind: "review",
                         response_due_at: ReportWorkQueue::REVIEW_DAYS.days.from_now)
          report.record_event!("forwarding_held_for_review", source: "background", metadata: { reason: "retired_preview" })
          ReportReviewAssistant.enqueue(report)
        end
      end
    end
  end
end
