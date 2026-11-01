# frozen_string_literal: true

require "active_support/notifications"
require_relative "dialogue/contracts"

module Decidim
  module Bih
    module Concierge
      # Fixed scalar labels only. The legacy event has no tenant dimension; the
      # detail event adds an internal organization partition. Neither receives
      # answer text, citizen identity, location or provider payloads.
      module AnswerOutcome
        EVENT = "milica.answer_outcome"
        DIMENSIONS_EVENT = "milica.answer_dimensions"
        INTENT_TOPICS = {
          "budget" => "budget", "donation" => "donation", "gazette" => "gazette", "waste" => "waste",
          "volunteer_guidance" => "volunteer", "participation_guidance" => "participation",
          "komsiluk_read" => "neighborhood", "komsiluk_post" => "neighborhood",
          "account_linking" => "account", "report" => "report", "report_guidance" => "report",
          "goodwill" => "goodwill", "launch" => "launch", "privacy" => "privacy"
        }.freeze
        # +provider_unavailable+ (the model provider failed) and +busy+ (admission
        # refused) are counted under their own label here even though the daily
        # aggregate has no column for them yet; the reply boundary is the only
        # place they are recorded.
        OUTCOMES = %w(answered clarification handoff draft submitted cancelled unsupported source_unavailable delivery_failed
                      provider_unavailable busy safety_guidance fallback error blank legacy_success_unknown).freeze

        module_function

        def topic(value, answer_intent: nil)
          return value if Dialogue::Contracts::TOPICS.include?(value) && value != "unknown"

          INTENT_TOPICS.fetch(answer_intent, "unknown")
        end

        def record(topic:, answer_intent:, outcome:, resolution: nil)
          label = outcome_label(outcome, resolution)
          ActiveSupport::Notifications.instrument(EVENT, topic: self.topic(topic, answer_intent:), outcome: label)
        rescue StandardError
          # Observability cannot affect answering or aggregate persistence.
          nil
        end

        # Organization is an internal aggregate partition, never an exported
        # identifier. No text enters this event; callers derive a closed facet.
        def record_dimensions(organization_id:, topic:, answer_intent:, outcome:, resolution: nil, facet: nil) # rubocop:disable Metrics/ParameterLists
          return unless organization_id.is_a?(Integer) && organization_id.positive?

          facets = %w(contact website operator hours fee coverage status location schedule)
          ActiveSupport::Notifications.instrument(
            DIMENSIONS_EVENT, organization_id:, topic: self.topic(topic, answer_intent:),
                              outcome: outcome_label(outcome, resolution), facet: facets.include?(facet) ? facet : "unknown"
          )
        rescue StandardError
          nil
        end

        def outcome_label(outcome, resolution)
          return resolution if OUTCOMES.include?(resolution)
          return outcome if %w(fallback error blank).include?(outcome)

          "legacy_success_unknown"
        end
      end
    end
  end
end
