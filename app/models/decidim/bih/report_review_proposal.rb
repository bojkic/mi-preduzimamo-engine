# frozen_string_literal: true

module Decidim
  module Bih
    class ReportReviewProposal < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_report_review_proposals"
      self.filter_attributes += [:proposal_ciphertext]
      belongs_to :report, class_name: "Decidim::Bih::Report"
      belongs_to :decided_by, class_name: "Decidim::User", optional: true
      validates :input_digest, :prompt_version, presence: true
      validates :state, inclusion: { in: %w(generating ready unavailable stale) }
      validates :proposal_ciphertext, presence: true, if: -> { state == "ready" }
      validate :same_organization
      before_update :protect_proposal

      def proposal
        return {} if data_redacted_at || proposal_ciphertext.blank?

        Infobip::EncryptedJobEnvelope.open(proposal_ciphertext, purpose: "report-review-proposal", salt: "bih-review-proposal-v1")
      end

      def proposal=(value)
        self.proposal_ciphertext = Infobip::EncryptedJobEnvelope.seal(value, purpose: "report-review-proposal", salt: "bih-review-proposal-v1")
      end

      # Prefer a proposal for the actual current input, even if a newer row
      # belongs to an abandoned edit or failed attempt on different content.
      # This is a read-only selection; stale fallback remains visibly stale.
      def self.for_review(report)
        scope = report.review_proposals
        return unless scope.exists?

        # Only the case agent supplies current proposals; legacy rows are history.
        digest = Ai::ReportReviewContext.new(report).digest
        scope.find_by(input_digest: digest, prompt_version: Ai::CaseAgent::PROMPT_VERSION, state: "ready") ||
          scope.find_by(input_digest: digest, prompt_version: Ai::CaseAgent::PROMPT_VERSION) || scope.order(:id).last
      rescue Ai::ReportReviewContext::TooLarge
        scope.where(error_code: "context_too_large", prompt_version: Ai::CaseAgent::PROMPT_VERSION).order(:id).last || scope.order(:id).last
      end

      def current?
        data_redacted_at.nil? && state == "ready" && prompt_version == Ai::CaseAgent::PROMPT_VERSION && input_digest == Ai::ReportReviewContext.new(report).digest
      rescue Ai::ReportReviewContext::TooLarge
        false
      end

      # Case-agent actions expressed as the staff decision they would become.
      # "wait" has no decision: there is nothing to accept.
      CASE_AGENT_ACTIONS = { "send_initial" => "send", "answer_city" => "followup", "close" => "reject", "wait" => nil }.freeze

      # Values enter an editable human form only; never a command or a job.
      def suggested_values
        return {} if data_redacted_at

        value = proposal
        if prompt_version == Ai::CaseAgent::PROMPT_VERSION
          action = CASE_AGENT_ACTIONS.fetch(value["proposed_action"], value["proposed_action"])
          citizen = value.fetch("citizen_message", {})
          body = citizen["composed_text"].presence
          body ||= ReportTexts.render(citizen["template_key"], slots: citizen.fetch("slots", {}).compact_blank) if citizen["template_key"].present?
          return { "draft_action" => action, "category" => value.dig("routing", "category"), "body" => body,
                   "forwarding_note" => value.dig("city_message", "text"), "duplicate_reference" => value.dig("duplicate", "reference"),
                   "reason" => (action == "reject" ? body : nil), "ai_proposal_id" => id }.compact
        end
        {}
      end

      # Historical AI provenance must not strand staff edits. Rendering/batch
      # preview presents these as human values; the persisted draft is untouched
      # until the operator saves or confirms it. Stale case-agent links still fail.
      def self.staff_draft_values(report)
        values = report.review_draft.fetch("values", {}).deep_dup
        proposal = report.review_proposals.find_by(id: values["ai_proposal_id"]) if values["ai_proposal_id"].present?
        values.delete("ai_proposal_id") if proposal && proposal.prompt_version.start_with?("report-review-")
        values
      end

      private

      def same_organization
        errors.add(:decided_by, :invalid) if decided_by && decided_by.organization != report&.organization
      end

      def protect_proposal
        protected = %w(report_id prompt_version data_redacted_at)
        protected << "input_digest" unless state_in_database == "generating" && state == "ready" && prompt_version == Ai::CaseAgent::PROMPT_VERSION
        protected += %w(proposal_ciphertext model state finished_at) if state_in_database == "ready"
        return unless protected.any? { |key| will_save_change_to_attribute?(key) }

        errors.add(:base, "Review proposal is immutable")
        throw :abort
      end
    end
  end
end
