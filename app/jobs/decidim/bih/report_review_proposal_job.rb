# frozen_string_literal: true

module Decidim
  module Bih
    class ReportReviewProposalJob < ApplicationJob
      queue_as :reports

      # A worker shutdown between provider calls leaves this job's lease in
      # place; the retry keeps the job id, so it resumes that lease at once.
      # If the retry is lost too, ReportReviewProposalRecovery picks the lease
      # up once it is stale.
      retry_on Ai::CaseAgent::Interrupted, wait: 30.seconds, attempts: 10

      # recover_lease: set only by ReportReviewProposalRecovery; takes over a
      # stale lease without also retrying unavailable proposals.
      def perform(report_id, retry_failed: false, inbound_email_id: nil, recover_lease: false)
        report = Report.find_by(id: report_id)
        return unless report

        ReportReviewAssistant.new.call(report, retry_failed:, recover_stale: recover_lease, lease_owner: job_id,
                                               trigger: inbound_email_id && InboundEmail.find_by(id: inbound_email_id))
      end
    end
  end
end
