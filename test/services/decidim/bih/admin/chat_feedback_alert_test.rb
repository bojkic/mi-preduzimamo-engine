# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/admin/chat_feedback_alert"

module Decidim
  module Bih
    module Admin
      # The rule, the window and the labels, with no database and no clock.
      # The database-backed half (tenant scoping, the real grouped query) is
      # covered by the host test of the same name.
      class ChatFeedbackAlertTest < Minitest::Test
        NOW = Time.utc(2026, 9, 14, 9, 0)

        def bucket(rated:, negative:, answer_intent: "service", locale: "sr")
          ChatFeedbackAlert::Bucket.new(answer_intent:, locale:, rated:, negative:)
        end

        # ---------------------------------------------------------------
        # the rule
        # ---------------------------------------------------------------

        def test_it_fires_at_five_rated_turns_and_half_negative
          assert_equal ChatFeedbackAlert::ALERT, ChatFeedbackAlert.status(bucket(rated: 5, negative: 3))
        end

        def test_exactly_half_negative_is_over_the_threshold_not_under_it
          assert_equal ChatFeedbackAlert::ALERT, ChatFeedbackAlert.status(bucket(rated: 6, negative: 3))
        end

        def test_below_the_share_it_does_not_fire
          assert_equal ChatFeedbackAlert::BELOW_THRESHOLD, ChatFeedbackAlert.status(bucket(rated: 6, negative: 2))
        end

        # The whole point of the minimum: four unanimous complaints are not
        # evidence, and must never be reported as "100% negative".
        def test_below_the_minimum_it_is_insufficient_evidence_not_healthy
          status = ChatFeedbackAlert.status(bucket(rated: 4, negative: 4))

          assert_equal ChatFeedbackAlert::INSUFFICIENT, status
          refute_equal ChatFeedbackAlert::BELOW_THRESHOLD, status
          refute_includes status, "health"
        end

        def test_a_quiet_bucket_is_never_called_healthy
          refute_includes ChatFeedbackAlert.status(bucket(rated: 0, negative: 0)), "health"
          refute_includes ChatFeedbackAlert.status(bucket(rated: 20, negative: 1)), "health"
        end

        def test_the_thresholds_are_configurable_without_touching_the_rule
          assert_equal ChatFeedbackAlert::ALERT, ChatFeedbackAlert.status(bucket(rated: 3, negative: 2), minimum_rated: 3)
          assert_equal ChatFeedbackAlert::BELOW_THRESHOLD,
                       ChatFeedbackAlert.status(bucket(rated: 10, negative: 6), negative_share: 0.75)
        end

        # ---------------------------------------------------------------
        # the window
        # ---------------------------------------------------------------

        def test_the_query_asks_for_exactly_the_last_seven_days
          asked = nil
          alert(counts: lambda { |range|
            asked = range
            []
          }).rows

          assert_equal NOW - (7 * 86_400), asked.begin
          assert_equal NOW, asked.end
          refute asked.include?(NOW), "the window must not include its own end instant twice over"
          assert asked.include?(NOW - 1)
          refute asked.include?(NOW - (7 * 86_400) - 1), "a rating older than the window is outside it"
        end

        def test_the_window_is_reported_with_the_row
          row = alert(counts: ->(_range) { [["service", "sr", 6, 5]] }).rows.first

          assert_equal 7, row[:window_days]
          assert_equal "2026-09-07", row[:started_on]
          assert_equal "2026-09-14", row[:ended_on]
        end

        def test_a_different_window_is_honoured_end_to_end
          asked = nil
          alert(window_days: 30, counts: lambda { |range|
            asked = range
            []
          }).rows

          assert_equal NOW - (30 * 86_400), asked.begin
        end

        # ---------------------------------------------------------------
        # the row an operator sees
        # ---------------------------------------------------------------

        def test_every_row_is_labelled_rated_turn_feedback
          rows = alert(counts: ->(_range) { [["service", "sr", 6, 5], ["setup", "sr", 2, 2]] }).rows

          assert(rows.all? { |row| row[:measure] == "rated_turn_feedback" })
        end

        def test_a_thin_bucket_carries_no_percentage
          row = alert(counts: ->(_range) { [["setup", "sr", 4, 4]] }).rows.first

          assert_equal ChatFeedbackAlert::INSUFFICIENT, row[:status]
          assert_nil row[:negative_share_percent]
          assert_equal 4, row[:rated_turns]
        end

        def test_a_firing_bucket_carries_its_share
          row = alert(counts: ->(_range) { [["service", "sr", 33, 26]] }).rows.first

          assert_equal ChatFeedbackAlert::ALERT, row[:status]
          assert_equal 79, row[:negative_share_percent]
        end

        def test_rows_carry_no_text_identity_or_free_form_field
          row = alert(counts: ->(_range) { [["service", "sr", 6, 5]] }).rows.first
          allowed = [:measure, :incident_key, :answer_intent, :locale, :rated_turns, :negative_turns,
                     :negative_share_percent, :status, :window_days, :minimum_rated, :started_on, :ended_on]

          assert_equal [], (row.keys - allowed)
          assert(row.values.compact.all? { |value| value.is_a?(Integer) || value.is_a?(String) })
        end

        # An intent or locale read out of JSON metadata reaches an operator
        # email, so neither is trusted.
        def test_an_unknown_intent_or_malformed_locale_is_bounded
          row = alert(counts: ->(_range) { [["<script>alert(1)</script>", "sr'; DROP TABLE --", 6, 5]] }).rows.first

          assert_equal "unknown", row[:answer_intent]
          assert_equal "unknown", row[:locale]
          assert_equal "chat_feedback.unknown.unknown", row[:incident_key]
        end

        def test_a_cyrillic_locale_survives_bounding
          row = alert(counts: ->(_range) { [["status", "sr-Cyrl", 6, 5]] }).rows.first

          assert_equal "sr-Cyrl", row[:locale]
          assert_equal "chat_feedback.status.sr-Cyrl", row[:incident_key]
        end

        # ---------------------------------------------------------------
        # duplicate runs, threshold crossing, recovery
        # ---------------------------------------------------------------

        # Dedup in the alert channel keys on the incident key. If the key moved
        # with the count, every new rating would re-notify.
        def test_the_incident_key_does_not_move_when_the_counts_do
          first = alert(counts: ->(_range) { [["service", "sr", 6, 5]] }).rows.first
          later = alert(counts: ->(_range) { [["service", "sr", 33, 26]] }).rows.first

          assert_equal first[:incident_key], later[:incident_key]
          assert_equal "chat_feedback.service.sr", first[:incident_key]
        end

        def test_two_runs_over_the_same_data_produce_the_same_rows
          counts = ->(_range) { [["service", "sr", 6, 5], ["setup", "sr", 2, 2]] }

          assert_equal alert(counts:).rows, alert(counts:).rows
        end

        def test_crossing_the_threshold_turns_the_bucket_into_an_alert
          before = alert(counts: ->(_range) { [["service", "sr", 4, 4]] })
          after = alert(counts: ->(_range) { [["service", "sr", 5, 5]] })

          assert_empty before.alerting_rows
          assert_equal 1, after.alerting_rows.size
        end

        # Recovery has to be visible as the alerting row going away — that is
        # what the alert channel turns into a RESOLVED line.
        def test_a_recovered_bucket_stops_alerting_and_keeps_its_row
          recovered = alert(counts: ->(_range) { [["service", "sr", 20, 3]] })

          assert_empty recovered.alerting_rows
          assert_equal ChatFeedbackAlert::BELOW_THRESHOLD, recovered.rows.first[:status]
        end

        def test_a_bucket_that_left_the_window_entirely_produces_no_row
          assert_empty alert(counts: ->(_range) { [] }).rows
          assert_equal 0, alert(counts: ->(_range) { [] }).rated_turns_total
        end

        # ---------------------------------------------------------------
        # ordering and totals
        # ---------------------------------------------------------------

        def test_alerting_buckets_sort_before_thin_ones
          rows = alert(counts: lambda { |_range|
            [["setup", "sr", 2, 2], ["service", "sr", 33, 26], ["report_guidance", "sr", 11, 8]]
          }).rows

          assert_equal %w(service report_guidance setup), (rows.map { |row| row[:answer_intent] })
          assert_equal 46, alert(counts: lambda { |_range|
            [["setup", "sr", 2, 2], ["service", "sr", 33, 26], ["report_guidance", "sr", 11, 8]]
          }).rated_turns_total
        end

        # ---------------------------------------------------------------
        # 9a's backtest, as a fixture
        # ---------------------------------------------------------------

        # The five bucket-weeks the audit measured against live data, and the
        # thin buckets of the same weeks that must stay silent. Reproduced
        # read-only against production on 2026-09-14; see the task report.
        def test_the_audited_backtest_buckets_still_classify_the_same_way
          expected = {
            ["service", "sr", 27, 23] => ChatFeedbackAlert::ALERT,
            ["service", "sr", 7, 5] => ChatFeedbackAlert::ALERT,
            ["report_guidance", "sr", 11, 8] => ChatFeedbackAlert::ALERT,
            ["service", "sr", 33, 26] => ChatFeedbackAlert::ALERT,
            ["setup", "sr", 10, 10] => ChatFeedbackAlert::ALERT,
            ["status", "sr-Cyrl", 4, 4] => ChatFeedbackAlert::INSUFFICIENT,
            ["service", "sr", 2, 2] => ChatFeedbackAlert::INSUFFICIENT,
            ["komsiluk_read", "sr", 2, 2] => ChatFeedbackAlert::INSUFFICIENT,
            ["city_event", "sr", 1, 1] => ChatFeedbackAlert::INSUFFICIENT
          }

          expected.each do |(intent, locale, rated, negative), status|
            assert_equal status, ChatFeedbackAlert.status(bucket(rated:, negative:, answer_intent: intent, locale:)),
                         "#{intent}/#{locale} #{negative}/#{rated}"
          end
        end

        private

        def alert(counts:, window_days: ChatFeedbackAlert::WINDOW_DAYS)
          ChatFeedbackAlert.new(organization: :ignored_by_the_counts_seam, now: NOW, window_days:, counts:)
        end
      end
    end
  end
end
