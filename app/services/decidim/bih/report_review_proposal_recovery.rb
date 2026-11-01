# frozen_string_literal: true

module Decidim
  module Bih
    # Backstop for case-agent leases whose worker is gone: process killed,
    # job lost on a hard stop, or interrupted retries exhausted. A job re-run
    # after Sidekiq::Shutdown resumes its own lease itself (Ai::CaseAgent);
    # this sweep only acts on leases older than CaseAgent::STALE_LEASE, so a
    # live worker's lease is never taken. Runs from the five-minute mailbox
    # recovery tick and, as a daily backstop, from ReportCaseReminderJob.
    class ReportReviewProposalRecovery
      # Older leases are left to staff and the explicit retry: the sweep
      # recovers recent restarts, it does not re-run historic strandings.
      WINDOW = 12.hours
      LIMIT = 50

      def self.run!(organization_id: nil)
        now = Time.current
        scope = ReportReviewProposal.where(state: "generating", prompt_version: Ai::CaseAgent::PROMPT_VERSION)
                                    .where(updated_at: (now - WINDOW)...(now - Ai::CaseAgent::STALE_LEASE))
        scope = scope.joins(:report).where(decidim_bih_reports: { decidim_organization_id: organization_id }) if organization_id
        scope.order(:updated_at).limit(LIMIT).includes(:report).to_a.filter_map { |proposal| new(proposal).call }
      rescue StandardError => e
        # Both host ticks do other recovery work; this sweep must not stop it.
        Rails.logger.warn("[ReportReviewProposalRecovery] sweep error=#{e.class}")
        []
      end

      def initialize(proposal)
        @proposal = proposal
        @report = proposal.report
      end

      # :enqueued, :abandoned or nil (left for the next tick).
      def call
        if ReportWorkQueue.closed?(@report) || superseded?
          abandon! ? :abandoned : nil
        elsif ReportReviewAssistant.active?(@report.organization) && ReportReviewAssistant.eligible?(@report)
          # The job re-checks the lease under the report lock; a fresh lease
          # taken meanwhile makes it a no-op, never a second generation.
          ReportReviewProposalJob.perform_later(@report.id, recover_lease: true)
          :enqueued
        end
      rescue StandardError => e
        Rails.logger.warn("[ReportReviewProposalRecovery] proposal=#{@proposal.id} error=#{e.class}")
        nil
      end

      private

      # The agent only ever reopens the row for the report's current input,
      # so a row for older input can never complete. Close it, keep it.
      def superseded?
        # Same order as Ai::CaseAgent#call: evidence items feed the digest.
        ReportEvidenceItem.sync!(@report)
        Ai::ReportReviewContext.new(@report).digest != @proposal.input_digest
      rescue Ai::ReportReviewContext::TooLarge
        true
      end

      def abandon!
        lease = @proposal.updated_at
        @report.with_lock do
          @proposal.lock!
          next false unless @proposal.state == "generating" && @proposal.updated_at == lease

          @proposal.update!(state: "unavailable", error_code: "interrupted", failure_reason: "interrupted", finished_at: Time.current)
          @report.record_event!("case_agent_lease", source: "background", actor_role: "system",
                                                    metadata: { proposal_id: @proposal.id, lease: "abandoned", prompt_version: @proposal.prompt_version })
          true
        end
      end
    end
  end
end
