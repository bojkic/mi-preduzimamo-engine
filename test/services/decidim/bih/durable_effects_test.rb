# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/numeric/time"
require_relative "../../../../app/services/decidim/bih/durable_effects"

module Decidim
  module Bih
    class DurableEffectsTest < Minitest::Test
      class FakeJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob -- pure engine test has no host ApplicationJob
        class << self
          attr_reader :calls

          def name = "Decidim::Bih::ReportProcessingJob"

          def reset! = @calls = []

          def perform_later(*arguments, **keyword_arguments)
            @calls << [arguments, keyword_arguments]
            :enqueued
          end
        end
      end

      class FakeCache
        attr_reader :writes

        def initialize = @writes = []

        def write(key, value, **options)
          writes << [key, value, options]
          true
        end
      end

      class EnqueueErrorAdapter
        attr_reader :enqueue_calls

        def initialize = @enqueue_calls = 0

        def enqueue(_job)
          @enqueue_calls += 1
          raise ActiveJob::EnqueueError, "adapter failure with private queue context"
        end

        def enqueue_at(job, _timestamp)
          enqueue(job)
        end
      end

      class AdapterFailureJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob -- pure engine test has no host ApplicationJob
        def self.name = "Decidim::Bih::ReportProcessingJob"
      end

      class FakeRedis
        attr_reader :sets, :deletes

        def initialize
          @sets = []
          @deletes = []
        end

        def set(key, value, **options)
          sets << [key, value, options]
          "OK"
        end

        def del(*keys)
          deletes << keys
          keys.size
        end
      end

      def setup
        FakeJob.reset!
        @previous_job = Decidim::Bih.const_get(:ReportProcessingJob, false) if
          Decidim::Bih.const_defined?(:ReportProcessingJob, false)
        Decidim::Bih.send(:remove_const, :ReportProcessingJob) if @previous_job
        Decidim::Bih.const_set(:ReportProcessingJob, FakeJob)
      end

      def teardown
        Decidim::Bih.send(:remove_const, :ReportProcessingJob) if
          Decidim::Bih.const_defined?(:ReportProcessingJob, false)
        Decidim::Bih.const_set(:ReportProcessingJob, @previous_job) if @previous_job
      end

      def test_operations_execute_immediately_without_an_inbound_context
        cache = FakeCache.new
        redis = FakeRedis.new
        deadline = 1.minute.from_now

        assert_equal :enqueued,
                     DurableEffects.enqueue(FakeJob, 42, locale: "bs", effect_expires_at: deadline)
        assert DurableEffects.cache_write("chat/key", { "turn" => 1 }, cache:, expires_in: 30.minutes)
        assert_equal "OK", DurableEffects.redis_set(redis:, key: "state/key", value: "next", ex: 600)
        assert_equal 1, DurableEffects.redis_delete("state/key", redis:)

        assert_equal [[[42], { locale: "bs" }]], FakeJob.calls
        assert_equal "chat/key", cache.writes.first[0]
        assert_equal({ "turn" => 1 }, cache.writes.first[1])
        assert_includes 1799..1800, cache.writes.first[2].fetch(:expires_in)
        assert_equal [["state/key", "next", { ex: 600 }]], redis.sets
        assert_equal [["state/key"]], redis.deletes
      end

      def test_capture_defers_allowlisted_effects_and_dispatch_restores_arguments
        cache = FakeCache.new
        redis = FakeRedis.new

        capture = DurableEffects.capture do
          DurableEffects.enqueue(FakeJob, 42, locale: "bs")
          DurableEffects.cache_write("chat/key", { "turn" => 1 }, cache:, expires_in: 30.minutes)
          DurableEffects.redis_set(redis:, key: "state/key", value: "next", ex: 600)
          DurableEffects.redis_delete("old/key", redis:)
          :handler_result
        end

        assert_equal :handler_result, capture.result
        assert_equal(
          %w(active_job cache_write redis_set redis_delete),
          capture.effects.map { |effect| effect["type"] }
        )
        assert_empty FakeJob.calls
        assert_empty cache.writes
        assert_empty redis.sets
        assert_empty redis.deletes

        capture.effects.each { |effect| DurableEffects.dispatch!(effect, cache:, redis:) }

        assert_equal [[[42], { locale: "bs" }]], FakeJob.calls
        assert_equal "chat/key", cache.writes.first[0]
        assert_equal({ "turn" => 1 }, cache.writes.first[1])
        assert_includes 1799..1800, cache.writes.first[2].fetch(:expires_in)
        assert_equal "state/key", redis.sets.first[0]
        assert_equal "next", redis.sets.first[1]
        assert_includes 599..600, redis.sets.first[2].fetch(:ex)
        assert_equal [["old/key"]], redis.deletes
      end

      def test_active_job_deadline_is_outer_metadata_and_not_a_job_keyword
        deadline = 1.minute.from_now
        capture = DurableEffects.capture do
          DurableEffects.enqueue(FakeJob, 42, locale: "bs", effect_expires_at: deadline)
        end
        effect = capture.effects.fetch(0)

        assert_equal "active_job", effect.fetch("type")
        assert_equal (deadline.to_time.to_f * 1000).ceil, effect.fetch("deadline_at_ms")
        refute_includes JSON.generate(effect.fetch("arguments")), "effect_expires_at"

        assert_equal :enqueued, DurableEffects.dispatch!(effect)
        assert_equal [[[42], { locale: "bs" }]], FakeJob.calls
      end

      def test_expired_active_jobs_and_tombstones_are_safe_no_ops
        captured_expired = DurableEffects.capture do
          DurableEffects.enqueue(FakeJob, 42, effect_expires_at: Time.at(1).utc)
        end

        assert_equal [DurableEffects.tombstone], captured_expired.effects
        assert_equal :tombstone, DurableEffects.dispatch!(captured_expired.effects.first)

        captured_future = DurableEffects.capture do
          DurableEffects.enqueue(FakeJob, 43, effect_expires_at: 1.minute.from_now)
        end
        captured_future.effects.first["deadline_at_ms"] = 1

        assert_equal :expired, DurableEffects.dispatch!(captured_future.effects.first)
        assert_empty FakeJob.calls
        assert_raises(ArgumentError) do
          DurableEffects.dispatch!("type" => "tombstone", "payload" => "must not survive")
        end
      end

      def test_missing_global_id_is_consumed_before_enqueue
        capture = DurableEffects.capture { DurableEffects.enqueue(FakeJob, 42) }
        error = deserialization_error("GlobalID target was deleted")

        result = ActiveJob::Arguments.stub(:deserialize, ->(*) { raise error }) do
          DurableEffects.dispatch!(capture.effects.first)
        end

        assert_equal :discarded, result
        assert_empty FakeJob.calls
      end

      def test_deserialization_error_from_job_enqueue_is_not_consumed
        capture = DurableEffects.capture { DurableEffects.enqueue(FakeJob, 42) }
        error = deserialization_error("queue adapter raised after deserialization")

        assert_raises(ActiveJob::DeserializationError) do
          FakeJob.stub(:perform_later, ->(*) { raise error }) do
            DurableEffects.dispatch!(capture.effects.first)
          end
        end
      end

      def test_false_active_job_enqueue_result_is_retryable_and_sanitized
        capture = DurableEffects.capture { DurableEffects.enqueue(FakeJob, "private-citizen-copy") }

        error = assert_raises(DurableEffects::EnqueueError) do
          FakeJob.stub(:perform_later, false) do
            DurableEffects.dispatch!(capture.effects.first)
          end
        end

        assert_equal "Durable inbound ActiveJob enqueue failed", error.message
        refute_includes error.message, "private-citizen-copy"
      end

      def test_active_job_enqueue_error_captured_as_false_remains_retryable
        adapter = EnqueueErrorAdapter.new
        AdapterFailureJob.queue_adapter = adapter
        capture = DurableEffects.capture { DurableEffects.enqueue(AdapterFailureJob, 42) }

        error = with_report_processing_job(AdapterFailureJob) do
          assert_raises(DurableEffects::EnqueueError) do
            DurableEffects.dispatch!(capture.effects.first)
          end
        end

        assert_equal 1, adapter.enqueue_calls
        assert_equal "Durable inbound ActiveJob enqueue failed", error.message
        refute_includes error.message, "private queue context"
      end

      def test_expired_cache_and_redis_writes_are_dropped_instead_of_revived
        cache = FakeCache.new
        redis = FakeRedis.new
        capture = DurableEffects.capture do
          DurableEffects.cache_write("chat/key", "old", cache:, expires_in: 30.minutes)
          DurableEffects.redis_set(redis:, key: "state/key", value: "old", ex: 600)
        end
        capture.effects.each { |effect| effect["deadline_at_ms"] = 1 }

        results = capture.effects.map { |effect| DurableEffects.dispatch!(effect, cache:, redis:) }

        assert_equal [:expired, :expired], results
        assert_empty cache.writes
        assert_empty redis.sets
      end

      def test_disallowed_job_and_unsupported_options_are_rejected_before_capture_can_commit
        disallowed_job = Class.new do
          def self.name = "DangerousJob"
        end

        assert_raises(ArgumentError) do
          DurableEffects.capture { DurableEffects.enqueue(disallowed_job, "secret") }
        end
        assert_raises(ArgumentError) do
          DurableEffects.capture do
            DurableEffects.cache_write("key", "value", cache: FakeCache.new, raw: true)
          end
        end
        assert_raises(ArgumentError) do
          DurableEffects.capture { DurableEffects.enqueue(FakeJob, 1, effect_expires_at: false) }
        end
        refute DurableEffects.active?
      end

      def test_nested_capture_is_rejected_without_clearing_outer_context
        capture = DurableEffects.capture do
          assert_raises(ArgumentError) { DurableEffects.capture { flunk "must not run" } }
          assert DurableEffects.active?
          DurableEffects.enqueue(FakeJob, 7)
        end

        assert_equal 1, capture.effects.size
        refute DurableEffects.active?
      end

      private

      def deserialization_error(message)
        raise message
      rescue StandardError
        ActiveJob::DeserializationError.new
      end

      def with_report_processing_job(job_class)
        Decidim::Bih.send(:remove_const, :ReportProcessingJob)
        Decidim::Bih.const_set(:ReportProcessingJob, job_class)
        yield
      ensure
        Decidim::Bih.send(:remove_const, :ReportProcessingJob) if
          Decidim::Bih.const_defined?(:ReportProcessingJob, false)
        Decidim::Bih.const_set(:ReportProcessingJob, FakeJob)
      end
    end
  end
end
