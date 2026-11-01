# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/messaging/reconciliation"

module Decidim
  module Bih
    module Messaging
      # The report classifies. It does not mutate, it does not requeue, and it
      # does not decide that an unknown outcome was probably a failure.
      #
      # Pure on purpose: `classify` takes rows and returns counts, so the rules
      # are testable without a schema and cannot quietly acquire a write.
      class ReconciliationTest < Minitest::Test
        Row = Struct.new(:status, :reason, :channel, :channel_group, :claimed_at, :settled_at,
                         keyword_init: true)

        def row(**attrs)
          Row.new(status: "accepted", reason: nil, channel: "viber", channel_group: "external_copy",
                  claimed_at: nil, settled_at: nil, **attrs)
        end

        def test_stuck_is_claimed_long_ago_and_never_settled
          rows = [row(status: "claimed", claimed_at: Time.at(0).utc)]

          assert_equal 1, Reconciliation.classify(rows, now: Time.at(3600).utc)[:stuck]
        end

        # A leg with an ANSWER is never stuck, however old the claim is. Only
        # the two unresolved statuses can be; anything else has a result an
        # operator would be re-running for no reason.
        def test_a_leg_that_has_an_outcome_is_never_stuck_however_old_it_is
          %w(accepted delivered uncertain skipped failed expired).each do |status|
            rows = [row(status:, claimed_at: Time.at(0).utc, settled_at: Time.at(1).utc)]

            assert_equal 0, Reconciliation.classify(rows, now: Time.at(999_999).utc)[:stuck], status
          end
        end

        def test_a_queued_leg_that_was_never_claimed_is_not_counted_as_stuck
          rows = [row(status: "queued", claimed_at: nil)]

          assert_equal 0, Reconciliation.classify(rows, now: Time.at(999_999).utc)[:stuck]
        end

        def test_a_recent_claim_is_not_yet_stuck
          rows = [row(status: "claimed", claimed_at: Time.at(3000).utc)]

          assert_equal 0, Reconciliation.classify(rows, now: Time.at(3600).utc)[:stuck]
        end

        # The distinction the whole ledger exists for: an uncertain outcome may
        # already have been sent and paid for. Counting it as a failure invites
        # somebody to "retry the failures".
        def test_unknown_is_its_own_class_and_is_not_a_failure
          summary = Reconciliation.classify([row(status: "uncertain", reason: "worker_interrupted")],
                                            now: Time.at(3600).utc)

          assert_equal 1, summary[:unknown]
          assert_equal 0, summary[:failed]
          assert_equal({ "worker_interrupted" => 1 }, summary[:reasons])
        end

        def test_expired_and_skipped_are_counted_apart_from_failed
          rows = [row(status: "expired"), row(status: "skipped", reason: "ineligible"), row(status: "failed")]
          summary = Reconciliation.classify(rows, now: Time.at(0).utc)

          assert_equal 1, summary[:expired]
          assert_equal 1, summary[:skipped]
          assert_equal 1, summary[:failed]
        end

        def test_the_report_returns_counts_only_and_does_not_mutate_its_input
          rows = [row(status: "accepted", reason: "smtp_accepted", channel: "email")]
          before = rows.map(&:to_h)
          summary = Reconciliation.classify(rows, now: Time.at(0).utc)

          assert(summary.values.all? { |value| value.is_a?(Integer) || value.is_a?(Hash) || value.is_a?(Array) })
          assert_equal before, rows.map(&:to_h), "classify must not mutate its input"
        end

        def test_class_coverage_names_the_classes_with_no_attempts_at_all
          summary = Reconciliation.classify([], now: Time.at(0).utc,
                                                expected_classes: %w(report.author_external_copy city.service_alert_viber),
                                                observed_classes: %w(report.author_external_copy))

          assert_equal %w(city.service_alert_viber), summary[:classes_without_attempts]
        end

        def test_a_correlation_gap_is_reported_not_repaired
          assert_equal 3, Reconciliation.classify([], now: Time.at(0).utc, orphan_intents: 3)[:intents_without_attempts]
        end

        def test_channel_and_status_histograms_are_deterministic_and_identifier_free
          rows = [row(channel: "viber"), row(channel: "email", status: "uncertain"), row(channel: "viber")]
          summary = Reconciliation.classify(rows, now: Time.at(0).utc)

          assert_equal({ "email" => 1, "viber" => 2 }, summary[:by_channel])
          assert_equal({ "accepted" => 2, "uncertain" => 1 }, summary[:by_status])
          refute_match(/@|\+387|[0-9a-f]{64}/, summary.to_s)
        end
      end
    end
  end
end
