# frozen_string_literal: true

module Decidim
  module Bih
    # How often the case agent's suggested action matched the staff
    # decision that followed it, whether or not staff pressed "accept".
    # Derived from existing proposals and decision events; nothing is stored.
    module ReportAiAgreement
      SUBSTANTIVE = %w(send ask reject duplicate plan review resolve followup supplement).freeze
      # Validating and sending are one outcome: staff often validate first and
      # send in a second step.
      SAME = { "review" => "send", "send_initial" => "send", "close" => "reject", "answer_city" => "followup" }.freeze

      module_function

      def summary(organization)
        proposals = ReportReviewProposal.joins(:report).where(decidim_bih_reports: { decidim_organization_id: organization.id })
                                        .where(state: "ready", data_redacted_at: nil).where("prompt_version LIKE ?", "case-agent-%")
        key = ["bih-ai-agreement", "case-agent", organization.id, proposals.maximum(:id),
               ReportEvent.where(organization:, event_type: "case_decision_applied").maximum(:id)]
        Rails.cache.fetch(key, expires_in: 1.hour) { compute(proposals) }
      end

      def compute(proposals)
        result = { compared: 0, agreed: 0, waiting: 0 }
        proposals.includes(:report).find_each do |proposal|
          suggested = proposal.proposal["proposed_action"]
          decided = staff_action(proposal)
          next result[:waiting] += 1 if decided.nil?

          result[:compared] += 1
          result[:agreed] += 1 if same?(suggested, decided)
        rescue StandardError
          next
        end
        result
      end

      def staff_action(proposal)
        proposal.report.events.where(event_type: "case_decision_applied").where(occurred_at: proposal.created_at..).order(:id)
                .map { |event| event.metadata["action"] }.find { |action| SUBSTANTIVE.include?(action) }
      end

      def same?(suggested, decided)
        SAME.fetch(suggested.to_s, suggested.to_s) == SAME.fetch(decided.to_s, decided.to_s)
      end
    end
  end
end
