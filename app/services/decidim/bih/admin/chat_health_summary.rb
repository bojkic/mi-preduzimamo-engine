# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # PII-safe read model for the operator's chat-health tab.
      #
      # Every reader returns +nil+ where the platform has no instrumentation for a
      # figure (no column, no table, Sidekiq unreadable), so the view prints
      # "unknown" instead of a confident zero. Zero is returned only when a query
      # ran against an existing table and found nothing.
      #
      # Contract: counts, dates and bounded labels only. Never text, senders,
      # session digests, user names or contact fields.
      class ChatHealthSummary
        PERIODS = [7, 30].freeze
        DEFAULT_PERIOD = 7
        # Resolutions the daily usage aggregate has a column for.
        COLUMNED_RESOLUTIONS = %w(answered clarification handoff unsupported source_unavailable).freeze
        # Counted only at the reply boundary (Redis); the daily aggregate folds
        # them into the legacy outcome=fallback total.
        UNCOLUMNED_RESOLUTIONS = %w(provider_unavailable busy).freeze
        FAILURE_OUTCOMES = %w(fallback error).freeze
        # Channels whose inbound path has no durable receipt table.
        UNINSTRUMENTED_INBOUND_CHANNELS = %w(web_chat).freeze
        EXHAUSTED_JOB_CLASS = "Decidim::Bih::Infobip::SendChatTextJob"
        LATENCY_STAGE = "understanding"
        PERCENTILES = { p50: 0.5, p95: 0.95 }.freeze

        def self.period(value)
          PERIODS.include?(value.to_i) ? value.to_i : DEFAULT_PERIOD
        end

        def initialize(organization:, period_days: DEFAULT_PERIOD, now: Time.current)
          @organization = organization
          @period_days = self.class.period(period_days)
          @now = now
        end

        attr_reader :organization, :period_days, :now

        def today
          now.in_time_zone.to_date
        end

        # Calendar days covered, today included.
        def period_range
          (today - (period_days - 1))..today
        end

        # Receipts are deleted after InboundDelivery::RETENTION, so the inbound
        # table can never answer for a longer window than that.
        def inbound_window_days
          [period_days, inbound_retention_days].min
        end

        def inbound_window_clamped?
          period_days > inbound_retention_days
        end

        def inbound_retention_days
          (Decidim::Bih::Viber::InboundDelivery::RETENTION / 1.day).to_i
        end

        # { "answered" => Integer, ..., "provider_unavailable" => nil, "busy" => nil }
        def resolutions
          @resolutions ||= begin
            sums = usage_scope.pick(*COLUMNED_RESOLUTIONS.map { |name| Arel.sql("COALESCE(SUM(resolution_#{name}_count), 0)") })
            columned = COLUMNED_RESOLUTIONS.zip(Array(sums)).to_h { |name, value| [name, value.to_i] }
            columned.merge(UNCOLUMNED_RESOLUTIONS.index_with { nil })
          end
        end

        # { "fallback" => Integer, "error" => Integer, "requests" => Integer }
        def failures
          @failures ||= begin
            by_outcome = usage_scope.group(:outcome).sum(:requests_count)
            FAILURE_OUTCOMES.index_with { |outcome| by_outcome.fetch(outcome, 0).to_i }
                            .merge("requests" => by_outcome.values.sum.to_i)
          end
        end

        # One row per channel: instrumented channels carry state counts and the
        # last receipt time; web chat carries nils because nothing records it.
        def inbound_channels
          @inbound_channels ||= begin
            scope = Decidim::Bih::Viber::InboundDelivery
                    .where(organization:)
                    .where(received_at: (now - inbound_window_days.days)..now)
            by_state = scope.group(:channel, :state).count
            last_seen = scope.group(:channel).maximum(:received_at)

            uninstrumented = UNINSTRUMENTED_INBOUND_CHANNELS.map do |channel|
              { channel:, instrumented: false, states: nil, total: nil, last_inbound_at: nil }
            end
            instrumented = Decidim::Bih::Viber::InboundDelivery::CHANNELS.map do |channel|
              states = Decidim::Bih::Viber::InboundDelivery::STATES.index_with { |state| by_state.fetch([channel, state], 0) }
              { channel:, instrumented: true, states:, total: states.values.sum, last_inbound_at: last_seen[channel] }
            end
            uninstrumented + instrumented
          end
        end

        # Sidekiq sets are platform-wide (job payloads are encrypted, so they
        # cannot be scoped per organization). Unreadable Sidekiq is +available:
        # false+ with nil counts, never zero.
        def exhausted_sends
          @exhausted_sends ||= read_sidekiq_sets
        end

        def rollup_available?
          rollup_scope.exists?
        end

        # Per rolled-up day: recorded answers, technical failures and their share.
        # Days without rows are absent — the view must say unknown, not zero.
        def rollup_days
          @rollup_days ||= begin
            sums = rollup_scope.where(kind: "answer").group(:day, :label).sum(:count)
            by_day = sums.group_by { |(day, _label), _count| day }
            by_day.keys.sort.map { |day| rollup_day_row(day, by_day.fetch(day)) }
          end
        end

        # Understanding-stage latency histogram summed over the period, or nil
        # when no stage row was rolled up.
        def understanding_latency
          return @understanding_latency if defined?(@understanding_latency)

          sums = rollup_scope.where(kind: "stage", topic: LATENCY_STAGE).group(:label, :latency_bucket).sum(:count)
          @understanding_latency = if sums.empty?
                                     nil
                                   else
                                     buckets = Decidim::Bih::ConciergeMetricRollup::LATENCY_BUCKETS.map do |bucket|
                                       { bucket:, completed: sums.fetch(["completed", bucket], 0).to_i, failed: sums.fetch(["failed", bucket], 0).to_i }
                                     end
                                     completed = buckets.sum { |row| row[:completed] }
                                     {
                                       buckets:,
                                       completed:,
                                       failed: buckets.sum { |row| row[:failed] },
                                       percentiles: PERCENTILES.transform_values { |share| percentile_bucket(buckets, completed, share) }
                                     }
                                   end
        end

        # Release SHA and prompt version stamped on the newest rollup row.
        def release_stamp
          return @release_stamp if defined?(@release_stamp)

          row = rollup_scope.order(day: :desc, updated_at: :desc).first
          @release_stamp = row && { release_sha: row.release_sha, prompt_version: row.prompt_version, day: row.day }
        end

        private

        def usage_scope
          Decidim::Bih::ConciergeUsageAggregate.where(organization:, bucket_on: period_range)
        end

        def rollup_scope
          Decidim::Bih::ConciergeMetricRollup.where(organization:, day: period_range)
        end

        def read_sidekiq_sets
          return { available: false, dead: nil, retrying: nil } unless sidekiq_api_loaded?

          { available: true, dead: count_jobs(::Sidekiq::DeadSet.new), retrying: count_jobs(::Sidekiq::RetrySet.new) }
        rescue StandardError
          { available: false, dead: nil, retrying: nil }
        end

        # The engine does not depend on Sidekiq and `require "sidekiq"` alone
        # does not define the set classes; a host without Sidekiq reports unknown.
        def sidekiq_api_loaded?
          return true if defined?(::Sidekiq::DeadSet) && defined?(::Sidekiq::RetrySet)

          require "sidekiq/api"
          defined?(::Sidekiq::DeadSet) && defined?(::Sidekiq::RetrySet) ? true : false
        rescue LoadError
          false
        end

        def count_jobs(set)
          entries = set.respond_to?(:scan) ? set.scan(EXHAUSTED_JOB_CLASS) : set
          entries.count { |job| job_class_of(job) == EXHAUSTED_JOB_CLASS }
        end

        def job_class_of(job)
          return job.display_class if job.respond_to?(:display_class)

          item = job.respond_to?(:item) ? job.item : {}
          item["wrapped"] || item["class"]
        end

        def rollup_day_row(day, label_sums)
          answers = label_sums.sum { |_key, count| count }
          failures = label_sums.sum do |(_day, label), count|
            Decidim::Bih::ConciergeMetricRollup::TECHNICAL_FAILURE_LABELS.include?(label) ? count : 0
          end
          {
            day:,
            answers:,
            technical_failures: failures,
            failure_rate_percent: answers.positive? ? (failures * 100.0 / answers).round(1) : nil
          }
        end

        # First bucket whose cumulative completed count reaches +share+.
        def percentile_bucket(buckets, completed, share)
          return nil unless completed.positive?

          threshold = completed * share
          cumulative = 0
          buckets.each do |row|
            cumulative += row[:completed]
            return row[:bucket] if cumulative >= threshold
          end
          buckets.last[:bucket]
        end
      end
    end
  end
end
