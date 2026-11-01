# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # One grouped read supplies both the table and its denominator. Cohorts
      # are mutually exclusive: legacy and capture-dimension counters overlap
      # and MUST NOT be added together. These are observed answer boundaries,
      # not unique citizens, sessions, helpfulness or factual accuracy.
      class ConciergeMetricsSummary
        PERIODS = [7, 30].freeze
        COHORTS = %w(captured legacy).freeze
        TRAFFIC_FILTERS = %w(all unclassified synthetic).freeze
        MIN_SAMPLE = 5
        HEADERS = %w(row_kind window_started_on window_ended_on timezone cohort measurement_scope traffic_filter topic facet typed_outcome
                     traffic_kind release_sha release_scope prompt_version sample_size count privacy_status coverage_status).freeze
        GROUP_FIELDS = [:topic, :facet, :label, :traffic_kind, :release_sha, :prompt_version].freeze

        def initialize(organization:, now: Time.current, period: nil, cohort: nil, traffic: nil, model: nil) # rubocop:disable Metrics/ParameterLists
          @organization = organization
          @model = model || Decidim::Bih::ConciergeMetricRollup
          @now = now
          @period = PERIODS.include?(period.to_i) ? period.to_i : 7
          @cohort = COHORTS.include?(cohort) ? cohort : "captured"
          @traffic = TRAFFIC_FILTERS.include?(traffic) ? traffic : "all"
        end

        attr_reader :period, :cohort, :traffic

        # Complete Sarajevo calendar days only. Today's partial day and a
        # rolling-hour request have different denominators and are excluded.
        def ended_on = @now.in_time_zone("Europe/Sarajevo").to_date - 1

        def started_on = ended_on - (period - 1)

        def filters = { period:, cohort:, traffic: }

        def rows
          @rows ||= build_rows
        end

        def summary
          rows.first
        end

        private

        def grouped_counts
          scope = @model.where(organization: @organization, day: started_on..ended_on,
                               kind: cohort == "captured" ? "answer_detail" : "answer")
          scope = scope.where(traffic_kind: traffic) unless traffic == "all"
          scope.group(*GROUP_FIELDS).sum(:count)
        end

        def build_rows
          # The legacy cohort has no synthetic provenance; a filtered absence
          # must not become evidence that historical synthetic traffic was zero.
          return [base.merge(row_kind: "total", coverage_status: "unsupported_legacy_filter", privacy_status: "not_recorded")] if cohort == "legacy" && traffic != "all"

          groups = grouped_counts.select { |_dimensions, count| count.positive? }
          return [base.merge(row_kind: "total", coverage_status: "not_recorded", privacy_status: "not_recorded")] if groups.empty?

          sparse = groups.any? { |_dimensions, count| count < MIN_SAMPLE }
          total = groups.values.sum
          # Complementary suppression: an exact total would reveal a hidden
          # small cell by subtraction. Never publish the hidden cell's labels,
          # number of contributing buckets or exact total/denominator.
          sample = sparse ? nil : total
          summary = base.merge(row_kind: "total", count: sample, sample_size: sample,
                               privacy_status: sparse ? "suppressed" : "visible", coverage_status: "recorded_buckets_only")
          [summary, *detail_rows(groups, sample:)]
        end

        def detail_rows(groups, sample:)
          details = groups.filter_map do |values, count|
            next if count < MIN_SAMPLE

            dimensions = GROUP_FIELDS.zip(values).to_h
            base.merge(row_kind: "bucket", topic: dimensions[:topic], facet: cohort == "legacy" ? "not_recorded" : dimensions[:facet],
                       typed_outcome: dimensions[:label], traffic_kind: cohort == "legacy" ? "not_recorded" : dimensions[:traffic_kind],
                       release_sha: dimensions[:release_sha], prompt_version: dimensions[:prompt_version], count:,
                       sample_size: sample, privacy_status: "visible", coverage_status: "recorded_buckets_only")
          end
          details.sort_by { |row| [row[:topic], row[:facet], row[:typed_outcome], row[:traffic_kind], row[:release_sha].to_s, row[:prompt_version].to_i] }
        end

        def base
          { window_started_on: started_on.iso8601, window_ended_on: ended_on.iso8601, timezone: "Europe/Sarajevo",
            cohort:, measurement_scope: cohort == "captured" ? "tenant_partitioned_answer_boundaries" : "global_counters_assigned_at_rollup",
            traffic_filter: traffic, release_scope: cohort == "captured" ? "process_boot_checkout" : "rollup_checkout_not_capture",
            sample_size: nil, count: nil }
        end
      end
    end
  end
end
