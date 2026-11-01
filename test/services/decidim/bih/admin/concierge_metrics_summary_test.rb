# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/numeric/time"
require "active_support/core_ext/time/zones"
require "active_support/core_ext/date/calculations"
require_relative "../../../../../app/services/decidim/bih/admin/concierge_metrics_summary"

module Decidim
  module Bih
    module Admin
      class ConciergeMetricsSummaryTest < Minitest::Test
        class Relation
          def initialize(rows) = @rows = rows

          def where(**filters)
            self.class.new(@rows.select { |row| filters.all? { |key, value| value.is_a?(Range) ? value.cover?(row[key]) : row[key] == value } })
          end

          def group(*keys)
            @keys = keys
            self
          end

          def sum(field)
            @rows.group_by { |row| row.values_at(*@keys) }.transform_values { |rows| rows.sum { |row| row.fetch(field) } }
          end
        end

        def setup
          @now = Time.utc(2026, 9, 15, 12)
          @rows = []
        end

        def add(count: 5, **attributes)
          @rows << { organization: :one, day: Date.new(2026, 9, 14), kind: "answer_detail", topic: "water", facet: "status",
                     label: "answered", traffic_kind: "unclassified", release_sha: "a" * 40, prompt_version: 1, count: }.merge(attributes)
        end

        def report(**filters)
          ConciergeMetricsSummary.new(organization: :one, now: @now, model: Relation.new(@rows), **filters)
        end

        def test_one_filtered_population_reconciles_the_total_and_all_buckets
          add(count: 6)
          add(count: 4, day: Date.new(2026, 9, 13))
          add(count: 5, facet: "fee", label: "source_unavailable")
          add(count: 8, traffic_kind: "synthetic")
          add(count: 99, organization: :other)
          add(count: 99, kind: "read")
          add(count: 99, kind: "answer")
          add(count: 99, day: Date.new(2026, 9, 15)) # partial current day
          add(count: 99, day: Date.new(2026, 9, 7)) # outside 7 complete days

          rows = report(traffic: "unclassified").rows
          assert_equal 15, rows.first[:sample_size]
          assert_equal(rows.first[:count], rows.drop(1).sum { |row| row[:count] })
          assert_equal [5, 10], rows.drop(1).map { |row| row[:count] }.sort
          assert(rows.all? { |row| row[:window_started_on] == "2026-09-08" && row[:window_ended_on] == "2026-09-14" })
          assert_equal 23, report.summary[:sample_size]
          assert_equal 8, report(traffic: "synthetic").summary[:sample_size]
        end

        def test_sparse_dimensions_and_complementary_total_are_withheld
          add(count: 12)
          add(count: 1, topic: "health", facet: "contact", release_sha: "b" * 40)
          rows = report.rows
          assert_nil rows.first[:count]
          assert_nil rows.first[:sample_size]
          assert_equal "suppressed", rows.first[:privacy_status]
          assert_equal 2, rows.size
          assert_equal 12, rows.last[:count]
          assert_nil rows.last[:sample_size]
          refute_includes rows.to_s, "health"
          refute_includes rows.to_s, "b" * 40
        end

        def test_missing_buckets_and_unsupported_legacy_filter_never_mean_zero
          assert_equal "not_recorded", report.summary[:coverage_status]
          assert_nil report.summary[:count]
          add(kind: "answer", count: 5)
          legacy = report(cohort: "legacy")
          assert_equal "not_recorded", legacy.rows.last[:facet]
          assert_equal "not_recorded", legacy.rows.last[:traffic_kind]
          assert_equal "rollup_checkout_not_capture", legacy.rows.last[:release_scope]
          assert_equal "unsupported_legacy_filter", report(cohort: "legacy", traffic: "synthetic").summary[:coverage_status]
        end

        def test_release_boundaries_are_not_replaced_by_latest_rollup
          add(count: 5)
          add(count: 7, release_sha: "b" * 40, prompt_version: 2)
          assert_equal(["a" * 40, "b" * 40], report.rows.drop(1).map { |row| row[:release_sha] })
          assert_equal 12, report.summary[:count]
          assert_equal "process_boot_checkout", report.summary[:release_scope]
        end

        def test_filters_and_window_are_bounded_and_use_sarajevo_midnight
          metrics = report(period: "private", cohort: "private", traffic: "private")
          assert_equal({ period: 7, cohort: "captured", traffic: "all" }, metrics.filters)
          @now = Time.utc(2026, 9, 14, 22, 1)
          assert_equal Date.new(2026, 9, 14), report.ended_on
          assert_equal Date.new(2026, 8, 16), report(period: 30).started_on
        end
      end
    end
  end
end
