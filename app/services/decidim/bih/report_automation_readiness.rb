# frozen_string_literal: true

# rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- explicit independent policy and safety guards

module Decidim
  module Bih
    # Readiness is evidence, not activation. A ready model draft or owner consent
    # cannot substitute for a deployed transport policy and reviewed evaluation.
    class ReportAutomationReadiness
      POLICIES = %w(citizen_question evidence_handoff city_answer city_reminder).freeze
      MIN_CASES = 15
      MIN_AGREEMENT = 0.95
      SHADOW_DAYS = 7
      def initialize(organization:, now: Time.current)
        @organization = organization
        @now = now
      end

      def call
        settings = Setting.namespace_for(@organization, "report_automation")
        milestones = Setting.namespace_for(@organization, "report_rollout").fetch("verified_milestones", {})
        POLICIES.to_h do |policy|
          receipt = settings.fetch("evaluation_#{policy}", {})
          reasons = []
          reasons << "policy_not_deployed" if receipt["deployed_policy_version"].blank?
          reasons << "evaluation_gate_unverified" unless milestones.dig("T3.7", "evidence_digest").to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
          started = begin
            Time.iso8601(receipt["shadow_started_at"])
          rescue StandardError
            nil
          end
          reasons << "shadow_interval_incomplete" unless started && started <= @now - SHADOW_DAYS.days
          count = receipt["staff_reviewed_cases"].to_i
          reasons << "too_few_reviewed_cases" unless count >= MIN_CASES
          reasons << "agreement_below_threshold" unless count.positive? && receipt["agreed_cases"].to_i.fdiv(count) >= MIN_AGREEMENT
          unless (receipt["safety_failures"].is_a?(Integer) && receipt["safety_failures"].zero?) && receipt["safety_evidence_digest"].to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
            reasons << "safety_gate_unverified"
          end
          reasons << "owner_activation_missing" unless settings["owner_authorized"] == true
          [policy, { ready: reasons.empty?, reasons: }]
        end
      end
    end
  end
end

# rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
