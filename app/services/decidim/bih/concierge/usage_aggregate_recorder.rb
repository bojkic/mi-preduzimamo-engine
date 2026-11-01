# frozen_string_literal: true

require_relative "answer_outcome"

module Decidim
  module Bih
    module Concierge
      # Best-effort writer for aggregate concierge usage. It stores only daily
      # numeric counters and bounded labels, so answer-quality review can use
      # signals from all turns rather than only the small subset with feedback.
      class UsageAggregateRecorder
        # Additive event vocabulary for evaluators and future callers. The
        # persisted aggregate keeps its historical success/blank/fallback/error
        # buckets; these dimensions must not be substituted into +outcome+.
        RESOLUTIONS = %w(
          answered clarification handoff draft submitted cancelled unsupported
          source_unavailable delivery_failed provider_unavailable busy safety_guidance
        ).freeze
        # Resolutions backed by a daily counter column. +provider_unavailable+
        # and +busy+ have no column yet (no migration in this wave): they reach
        # the operator through the answer-outcome event and the per-turn log
        # line, and the aggregate row still counts the turn in its outcome
        # bucket. Adding a column later only needs the name listed here.
        PERSISTED_RESOLUTIONS = %w(
          answered clarification handoff draft submitted cancelled unsupported
          source_unavailable delivery_failed safety_guidance
        ).freeze
        RESOLUTION_COUNTERS = RESOLUTIONS.index_with { |resolution| "resolution_#{resolution}_count" }.freeze
        EVIDENCE_COUNTERS = {
          handoff_offered: "handoff_offered_count",
          handoff_completed: "handoff_completed_count",
          grounded_answer: "grounded_answer_count",
          action_receipt: "action_receipt_count"
        }.freeze
        DIALOGUE_COUNTER_COLUMNS = (RESOLUTION_COUNTERS.slice(*PERSISTED_RESOLUTIONS).values + EVIDENCE_COUNTERS.values).freeze
        OutcomeDimensions = Data.define(
          :resolution, :handoff_offered, :handoff_completed, :grounded_answer, :action_receipt
        )

        class << self
          def call(**attributes)
            new(attributes).call
          end

          def outcome_dimensions(resolution:, handoff_offered: false, handoff_completed: false, grounded_answer: false, action_receipt: false)
            normalized = resolution.to_s
            normalized = "unsupported" unless RESOLUTIONS.include?(normalized)
            # Contact guidance is neither a dispatch nor an action receipt.
            safety = normalized == "safety_guidance"
            OutcomeDimensions.new(
              resolution: normalized,
              handoff_offered: !safety && handoff_offered == true,
              handoff_completed: !safety && handoff_completed == true,
              grounded_answer: !safety && grounded_answer == true,
              action_receipt: !safety && action_receipt == true
            )
          end
        end

        def initialize(attributes)
          @organization = attributes.fetch(:organization)
          @channel = attributes.fetch(:channel)
          @outcome = attributes.fetch(:outcome)
          @answer_intent = attributes.fetch(:answer_intent)
          @topic = attributes[:topic]
          @facet = attributes[:facet]
          @locale = attributes.fetch(:locale, I18n.locale.to_s)
          @message_length = attributes.fetch(:message_length, 0)
          @reply_length = attributes.fetch(:reply_length, 0)
          @quick_replies_count = attributes.fetch(:quick_replies_count, 0)
          @sticker_present = attributes.fetch(:sticker_present, false)
          @occurred_at = attributes.fetch(:occurred_at, Time.current)
          @outcome_dimensions = normalize_outcome_dimensions(attributes[:outcome_dimensions])
        end

        def call
          return unless organization

          record_answer_outcome

          aggregate = find_or_create_aggregate
          aggregate.with_lock do
            aggregate.requests_count += 1
            aggregate.message_length_total += non_negative_integer(message_length)
            aggregate.reply_length_total += non_negative_integer(reply_length)
            aggregate.quick_replies_total += non_negative_integer(quick_replies_count)
            aggregate.sticker_count += 1 if sticker_present
            record_outcome_dimensions(aggregate)
            aggregate.save!
          end
          aggregate
        rescue ActiveRecord::RecordNotUnique
          raise if @retried

          @retried = true
          retry
        end

        private

        attr_reader :organization, :channel, :outcome, :answer_intent, :locale,
                    :message_length, :reply_length, :quick_replies_count,
                    :sticker_present, :occurred_at, :outcome_dimensions

        def record_answer_outcome
          return if @answer_outcome_recorded

          @answer_outcome_recorded = true
          AnswerOutcome.record(topic: @topic, answer_intent:, outcome: sanitized_outcome, resolution: outcome_dimensions&.resolution)
          AnswerOutcome.record_dimensions(organization_id: organization.id, topic: @topic, answer_intent:,
                                          outcome: sanitized_outcome, resolution: outcome_dimensions&.resolution, facet: @facet)
        end

        def find_or_create_aggregate
          Decidim::Bih::ConciergeUsageAggregate.find_or_create_by!(identity_attributes)
        end

        def identity_attributes
          {
            organization:,
            bucket_on: occurred_at.to_date,
            channel: sanitized_channel,
            outcome: sanitized_outcome,
            answer_intent: Decidim::Bih::Concierge::AnswerIntents.sanitize(answer_intent),
            locale: sanitized_locale
          }
        end

        def sanitized_channel
          value = channel.to_s
          Decidim::Bih::ConciergeUsageAggregate::CHANNELS.include?(value) ? value : "web_chat"
        end

        def sanitized_outcome
          value = outcome.to_s
          Decidim::Bih::ConciergeUsageAggregate::OUTCOMES.include?(value) ? value : "error"
        end

        def sanitized_locale
          locale.to_s.first(16).presence || I18n.default_locale.to_s
        end

        def normalize_outcome_dimensions(value)
          return if value.nil?
          return unless value.is_a?(OutcomeDimensions)

          self.class.outcome_dimensions(**value.to_h)
        end

        # Deploying the code before its additive migration must not break the
        # historical aggregate writer. Increment only after the complete fixed
        # counter set is visible to the loaded model; a partial schema records
        # the legacy aggregate and leaves all new dimensions unknown (zero).
        def record_outcome_dimensions(aggregate)
          return unless outcome_dimensions

          missing = DIALOGUE_COUNTER_COLUMNS.reject { |column| aggregate.has_attribute?(column) }
          unless missing.empty?
            ActiveSupport::Notifications.instrument("milica.outcome_dimensions_unavailable", resolution: outcome_dimensions.resolution, missing_columns: missing)
            if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
              Rails.logger.warn("[MilicaOutcomeDimensions] schema_incomplete resolution=#{outcome_dimensions.resolution} missing_count=#{missing.length}")
            end
            return
          end

          add_to_counter(aggregate, RESOLUTION_COUNTERS.fetch(outcome_dimensions.resolution))
          EVIDENCE_COUNTERS.each do |dimension, column|
            add_to_counter(aggregate, column) if outcome_dimensions.public_send(dimension)
          end
        end

        # A resolution in the vocabulary but without a column (yet) is skipped,
        # never an error: the turn is still counted in its outcome bucket and
        # every other dimension of the same turn is still recorded.
        def add_to_counter(aggregate, column)
          return unless aggregate.has_attribute?(column)

          aggregate[column] = non_negative_integer(aggregate[column]) + 1
        end

        def non_negative_integer(value)
          [value.to_i, 0].max
        end
      end
    end
  end
end
