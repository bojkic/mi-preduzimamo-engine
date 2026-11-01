# frozen_string_literal: true

require "test_helper"
# The REAL provider error, not a stub of it: `definitive_rejection?` is the one
# classification the whole fallback rule rests on, and a stub would let it drift.
require "active_support/core_ext/object/blank"
require_relative "../../../../../app/services/decidim/bih/infobip/error"
require_relative "../../../../../app/services/decidim/bih/messaging/outcome"

module Decidim
  module Bih
    module Messaging
      class OutcomeTest < Minitest::Test
        # Copied literally from Decidim::Bih::Messaging::Attempt::STATUSES,
        # which needs ActiveRecord and cannot be loaded here. The harness proves
        # the two lists never drift (see rails_test/messaging_router_test.rb).
        ATTEMPT_STATUSES = %w(queued claimed accepted delivered uncertain skipped failed expired).freeze

        def definitive(code) = Infobip::Error.new("refused", http_status: 400, error_code: code)

        def server_error(code) = Infobip::Error.new("boom", http_status: 503, error_code: code)

        def timeout(code) = Infobip::Error.new("no reply", error_code: code)

        # ---- the one load-bearing rule ---------------------------------------

        def test_only_a_definitive_rejection_authorizes_the_next_channel
          assert Outcome.authorizes_fallback?(Outcome::REJECTED)
          (Outcome::ALL - [Outcome::REJECTED]).each do |outcome|
            refute Outcome.authorizes_fallback?(outcome), "#{outcome.inspect} must not authorize another paid attempt"
          end
        end

        def test_a_timeout_is_uncertain_and_never_a_retry_instruction
          outcome = Outcome.classify(error: timeout("EC_TIMEOUT"))

          assert_equal Outcome::UNCERTAIN, outcome
          refute Outcome.authorizes_fallback?(outcome)
        end

        def test_a_5xx_is_uncertain_because_the_provider_may_already_have_sent
          outcome = Outcome.classify(error: server_error("EC_INTERNAL"))

          assert_equal Outcome::UNCERTAIN, outcome
          refute Outcome.authorizes_fallback?(outcome)
        end

        def test_a_definitive_4xx_provider_rejection_is_rejected
          assert_equal Outcome::REJECTED, Outcome.classify(error: definitive("EC_NOT_REACHABLE"))
        end

        def test_unknown_is_a_spelling_of_uncertain_not_a_second_state
          assert_equal Outcome::UNCERTAIN, Outcome::UNKNOWN
        end

        # ---- responses --------------------------------------------------------

        def test_a_response_without_message_ids_is_uncertain_not_accepted
          assert_equal Outcome::UNCERTAIN, Outcome.classify(response: { "messages" => [] })
          assert_equal Outcome::UNCERTAIN, Outcome.classify(response: {})
          assert_equal Outcome::UNCERTAIN, Outcome.classify(response: { "messages" => [{ "messageId" => "" }] })
        end

        def test_a_response_with_message_ids_is_accepted_not_delivered
          assert_equal Outcome::ACCEPTED, Outcome.classify(response: { "messages" => [{ "messageId" => "x" }] })
        end

        def test_no_signal_at_all_is_uncertain
          assert_equal Outcome::UNCERTAIN, Outcome.classify
        end

        # ---- delivery reports -------------------------------------------------

        def test_delivered_requires_an_explicit_handset_report
          assert_equal Outcome::DELIVERED,
                       Outcome.classify(report: { "status" => { "groupName" => "DELIVERED", "name" => "DELIVERED_TO_HANDSET" } })
          assert_equal Outcome::DELIVERED,
                       Outcome.classify(report: { "name" => "DELIVERED_TO_HANDSET" })
        end

        def test_a_pending_report_does_not_downgrade_what_we_already_knew
          assert_equal Outcome::ACCEPTED, Outcome.classify(report: { "name" => "PENDING_ENROUTE" }, previous: Outcome::ACCEPTED)
        end

        def test_a_rejected_or_undeliverable_report_is_a_definitive_rejection
          assert_equal Outcome::REJECTED, Outcome.classify(report: { "status" => { "groupName" => "REJECTED" } })
          assert_equal Outcome::REJECTED, Outcome.classify(report: { "status" => { "groupName" => "UNDELIVERABLE" } })
        end

        def test_an_expired_report_is_expired_and_does_not_authorize_a_new_attempt
          outcome = Outcome.classify(report: { "status" => { "groupName" => "EXPIRED" } })

          assert_equal Outcome::EXPIRED, outcome
          refute Outcome.authorizes_fallback?(outcome)
        end

        # ---- merge ------------------------------------------------------------

        def test_terminal_outcomes_cannot_be_downgraded
          assert_equal Outcome::DELIVERED, Outcome.merge(Outcome::DELIVERED, Outcome::ACCEPTED)
          assert_equal Outcome::REJECTED, Outcome.merge(Outcome::REJECTED, Outcome::UNCERTAIN)
          assert_equal Outcome::ACCEPTED, Outcome.merge(Outcome::ACCEPTED, Outcome::ACCEPTED)
        end

        def test_a_provider_acceptance_is_never_downgraded_to_skipped_or_expired
          assert_equal Outcome::ACCEPTED, Outcome.merge(Outcome::ACCEPTED, Outcome::SKIPPED)
          assert_equal Outcome::ACCEPTED, Outcome.merge(Outcome::ACCEPTED, Outcome::EXPIRED)
        end

        def test_uncertainty_beats_a_claim_that_nothing_was_sent
          assert_equal Outcome::UNCERTAIN, Outcome.merge(Outcome::SKIPPED, Outcome::UNCERTAIN)
          assert_equal Outcome::UNCERTAIN, Outcome.merge(Outcome::FAILED, Outcome::UNCERTAIN)
        end

        def test_a_later_delivery_report_still_wins
          assert_equal Outcome::DELIVERED, Outcome.merge(Outcome::UNCERTAIN, Outcome::DELIVERED)
        end

        # ---- ledger compatibility ---------------------------------------------

        def test_every_outcome_maps_onto_a_ledger_attempt_status
          Outcome::ALL.each do |outcome|
            status = Outcome.attempt_status(outcome)

            assert_includes ATTEMPT_STATUSES, status, "#{outcome.inspect} has no Attempt status to record it as"
          end
        end

        def test_a_definitive_rejection_is_recorded_as_a_failed_attempt
          assert_equal "failed", Outcome.attempt_status(Outcome::REJECTED)
          assert_equal "uncertain", Outcome.attempt_status(Outcome::UNCERTAIN)
          assert_equal "accepted", Outcome.attempt_status(Outcome::ACCEPTED)
        end
      end
    end
  end
end
