# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/enumerable"
require "active_support/core_ext/object/blank"
require "active_support/time"
require_relative "../../../../../app/services/decidim/bih/concierge/answer_intents"

# The recorder normally reads two enum constants from the ActiveRecord model.
# Provide them without a database when the real model is absent, and tear the
# stand-in down afterwards so it never shadows the real class in other files.
module Decidim
  module Bih
    unless const_defined?(:ConciergeUsageAggregate, false)
      class ConciergeUsageAggregate
        CHANNELS = %w(web_chat viber viber_bm whatsapp messenger instagram).freeze
        OUTCOMES = %w(success blank fallback error).freeze

        def self.find_or_create_by!(*) = raise("unexpected database query")
      end
      RECORDER_TEST_DEFINED_AGGREGATE = true
    end
  end
end

require_relative "../../../../../app/services/decidim/bih/concierge/usage_aggregate_recorder"

module Decidim
  module Bih
    module Concierge
      class UsageAggregateRecorderTest < Minitest::Test
        Organization = Struct.new(:id)
        PERSISTED_COUNTERS = %w(
          resolution_answered_count resolution_clarification_count resolution_handoff_count
          resolution_draft_count resolution_submitted_count resolution_cancelled_count
          resolution_unsupported_count resolution_source_unavailable_count resolution_delivery_failed_count resolution_safety_guidance_count
          handoff_offered_count handoff_completed_count grounded_answer_count action_receipt_count
        ).freeze

        # A row from the CURRENT schema: the thirteen dialogue counters exist,
        # the provider counters do not. Writing an unknown column raises, the
        # way a real ActiveRecord attribute assignment would.
        class FakeAggregate
          attr_accessor :requests_count, :message_length_total, :reply_length_total, :quick_replies_total, :sticker_count
          attr_reader :attributes, :saved

          def initialize(columns)
            @attributes = columns.index_with { 0 }
            @requests_count = @message_length_total = @reply_length_total = @quick_replies_total = @sticker_count = 0
            @saved = false
          end

          def has_attribute?(column) = attributes.has_key?(column.to_s)

          def [](column) = attributes.fetch(column.to_s)

          def []=(column, value)
            raise KeyError, "unknown column #{column}" unless has_attribute?(column)

            attributes[column.to_s] = value
          end

          def with_lock = yield

          def save! = @saved = true
        end

        # The recorder resolves the model constant on every call, so the
        # stand-in has to outlive each test; it is removed once the run ends.
        if Decidim::Bih.const_defined?(:RECORDER_TEST_DEFINED_AGGREGATE, false)
          Minitest.after_run do
            Decidim::Bih.send(:remove_const, :ConciergeUsageAggregate) if Decidim::Bih.const_defined?(:ConciergeUsageAggregate, false)
            Decidim::Bih.send(:remove_const, :RECORDER_TEST_DEFINED_AGGREGATE)
          end
        end

        def test_provider_unavailable_and_busy_are_part_of_the_resolution_vocabulary
          %w(provider_unavailable busy).each do |resolution|
            assert_includes UsageAggregateRecorder::RESOLUTIONS, resolution
            assert_equal resolution, UsageAggregateRecorder.outcome_dimensions(resolution:).resolution
          end
          assert_equal "unsupported", UsageAggregateRecorder.outcome_dimensions(resolution: "invented").resolution
        end

        def test_only_persisted_counters_gate_the_dialogue_dimension_write
          assert_equal PERSISTED_COUNTERS.sort, UsageAggregateRecorder::DIALOGUE_COUNTER_COLUMNS.sort
          assert_equal UsageAggregateRecorder::RESOLUTIONS.sort, UsageAggregateRecorder::RESOLUTION_COUNTERS.keys.sort
          refute_includes UsageAggregateRecorder::DIALOGUE_COUNTER_COLUMNS, "resolution_provider_unavailable_count"
          refute_includes UsageAggregateRecorder::DIALOGUE_COUNTER_COLUMNS, "resolution_busy_count"
        end

        def test_a_resolution_without_a_column_is_skipped_and_the_other_dimensions_still_count
          %w(provider_unavailable busy).each do |resolution|
            aggregate = FakeAggregate.new(PERSISTED_COUNTERS)
            recorder = build_recorder(outcome: "fallback", dimensions: UsageAggregateRecorder.outcome_dimensions(resolution:, handoff_offered: true))
            recorder.define_singleton_method(:find_or_create_aggregate) { aggregate }

            assert_same aggregate, recorder.call
            assert aggregate.saved
            assert_equal 1, aggregate.requests_count
            assert_equal 1, aggregate["handoff_offered_count"]
            refute aggregate.has_attribute?("resolution_#{resolution}_count")
            assert_equal(0, PERSISTED_COUNTERS.grep(/\Aresolution_/).sum { |column| aggregate[column] })
          end
        end

        def test_a_persisted_resolution_still_increments_its_own_counter
          aggregate = FakeAggregate.new(PERSISTED_COUNTERS)
          recorder = build_recorder(outcome: "success", dimensions: UsageAggregateRecorder.outcome_dimensions(resolution: "answered", grounded_answer: true))
          recorder.define_singleton_method(:find_or_create_aggregate) { aggregate }

          recorder.call

          assert_equal 1, aggregate["resolution_answered_count"]
          assert_equal 1, aggregate["grounded_answer_count"]
          assert_equal 0, aggregate["resolution_unsupported_count"]
        end

        # The honest-outcome fix (Task 9b) relabels the "no verified data"
        # refusal from "answered" to "unsupported". That must land in its own
        # counter and in the legacy fallback bucket, and it must NOT touch the
        # answered counter, or the operator's review keeps reading refusals as
        # successes.
        def test_a_refusal_counts_as_unsupported_and_never_as_an_answer
          aggregate = FakeAggregate.new(PERSISTED_COUNTERS)
          recorder = build_recorder(outcome: "fallback", dimensions: UsageAggregateRecorder.outcome_dimensions(resolution: "unsupported"))
          recorder.define_singleton_method(:find_or_create_aggregate) { aggregate }

          recorder.call

          assert_equal 1, aggregate["resolution_unsupported_count"]
          assert_equal 0, aggregate["resolution_answered_count"]
          assert_equal 0, aggregate["grounded_answer_count"]
        end

        # Legacy comparability: the coarse outcome bucket vocabulary is frozen,
        # so rows written before and after the relabelling remain comparable at
        # the bucket level while the resolution counters carry the new detail.
        def test_the_legacy_outcome_bucket_vocabulary_is_unchanged
          assert_equal %w(success blank fallback error), Decidim::Bih::ConciergeUsageAggregate::OUTCOMES
        end

        def test_a_partially_migrated_row_records_only_the_legacy_aggregate
          aggregate = FakeAggregate.new(PERSISTED_COUNTERS - %w(action_receipt_count))
          recorder = build_recorder(outcome: "success", dimensions: UsageAggregateRecorder.outcome_dimensions(resolution: "answered"))
          recorder.define_singleton_method(:find_or_create_aggregate) { aggregate }

          recorder.call

          assert_equal 1, aggregate.requests_count
          assert_equal 0, aggregate["resolution_answered_count"]
        end

        def test_safety_guidance_persists_its_own_counter_without_answer_or_dispatch_claims
          aggregate = FakeAggregate.new(PERSISTED_COUNTERS)
          dimensions = UsageAggregateRecorder.outcome_dimensions(
            resolution: "safety_guidance", handoff_offered: true, handoff_completed: true,
            grounded_answer: true, action_receipt: true
          )
          recorder = build_recorder(outcome: "fallback", dimensions:)
          recorder.define_singleton_method(:find_or_create_aggregate) { aggregate }
          events = []
          subscriber = ActiveSupport::Notifications.subscribe(AnswerOutcome::EVENT) { |*, payload| events << payload }
          recorder.call

          assert_equal 1, aggregate.requests_count
          assert_equal 1, aggregate["resolution_safety_guidance_count"]
          (PERSISTED_COUNTERS - %w(resolution_safety_guidance_count)).each { |column| assert_equal 0, aggregate[column], column }
          assert_equal "safety_guidance", events.last.fetch(:outcome)
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
        end

        def test_missing_safety_migration_is_observable_without_rewriting_historical_counters
          aggregate = FakeAggregate.new(PERSISTED_COUNTERS - %w(resolution_safety_guidance_count))
          aggregate["resolution_answered_count"] = 7
          recorder = build_recorder(outcome: "fallback", dimensions: UsageAggregateRecorder.outcome_dimensions(resolution: "safety_guidance"))
          recorder.define_singleton_method(:find_or_create_aggregate) { aggregate }
          events = []
          subscriber = ActiveSupport::Notifications.subscribe("milica.outcome_dimensions_unavailable") { |*, payload| events << payload }
          recorder.call

          assert_equal 1, aggregate.requests_count
          assert_equal 7, aggregate["resolution_answered_count"]
          assert_equal [{ resolution: "safety_guidance", missing_columns: ["resolution_safety_guidance_count"] }], events
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
        end

        private

        def build_recorder(outcome:, dimensions:)
          UsageAggregateRecorder.new(
            organization: Organization.new(1), channel: "web_chat", outcome:, answer_intent: "service",
            locale: "sr", message_length: 12, reply_length: 40, quick_replies_count: 0, sticker_present: false,
            occurred_at: Time.utc(2026, 9, 12, 10), outcome_dimensions: dimensions
          )
        end
      end
    end
  end
end
