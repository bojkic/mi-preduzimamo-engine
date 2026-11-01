# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/enumerable"
require_relative "../../../../../app/services/decidim/bih/concierge/dialogue/procedure_runner"
require_relative "../../../../../app/services/decidim/bih/concierge/confirmed_report_submission"
require_relative "../../../../../app/services/decidim/bih/concierge/usage_aggregate_recorder"
require_relative "../../../../../app/services/decidim/bih/concierge/reply_outcome"

module Decidim
  module Bih
    module Concierge
      class ReplyOutcomeTest < Minitest::Test
        def test_first_receipt_is_a_submission_but_replay_never_counts_another_effect
          [false, true].each do |replayed|
            receipt = ConfirmedReportSubmission::Receipt.new(reference: "MI-SYNTHETIC", replayed:)
            value = ReplyOutcome.from(receipt)
            assert_equal "report", value.topic
            assert_equal(replayed ? "answered" : "submitted", value.dimensions.resolution)
            assert_equal !replayed, value.dimensions.action_receipt
            refute value.dimensions.handoff_completed
            refute value.dimensions.handoff_offered
            assert value.factual_history
          end
        end

        def test_guidance_is_not_an_effect_and_typed_reads_keep_their_topic
          result = Dialogue::ProcedureRunner::Result.new(
            state: { "topic" => "neighborhood" }, reply: nil, resolution: "handoff",
            fact_ids: [], handoff_offered: true, handoff_completed: false
          )
          value = ReplyOutcome.from(result)
          assert_equal "neighborhood", value.topic
          assert_equal "handoff", value.dimensions.resolution
          assert value.dimensions.handoff_offered
          refute value.dimensions.action_receipt
          refute value.factual_history

          read = ReplyOutcome.from(result.with(resolution: "answered", fact_ids: ["notice:1"], handoff_offered: false))
          assert read.dimensions.grounded_answer
          assert read.factual_history
        end

        def test_typed_results_expose_structured_turn_facts_without_citizen_text
          result = Dialogue::ProcedureRunner::Result.new(
            state: {
              "topic" => "waste", "active_task" => "ask_information", "pending_slot" => "area_query",
              "clarification_count" => 2, "entities" => { "area_query" => "Dvorovi kod škole", "query" => "kad se odvozi" }
            },
            reply: nil, resolution: "clarification", fact_ids: [], handoff_offered: false, handoff_completed: false
          )
          value = ReplyOutcome.from(result)

          assert_equal "ask_information", value.action
          assert_equal "area_query", value.pending_slot
          assert_equal 2, value.clarification_count
          assert_equal %w(area_query query), value.entity_keys
          refute_includes value.to_h.values.flatten.map(&:to_s).join(" "), "Dvorovi"
        end

        def test_structured_turn_facts_are_bounded_and_default_for_receipts
          hostile = Dialogue::ProcedureRunner::Result.new(
            state: { "topic" => "waste", "active_task" => "rm -rf /", "pending_slot" => "x y", "clarification_count" => 99,
                     "entities" => { "Ulica Kralja Petra 7" => "x", "area_query" => "y" } },
            reply: nil, resolution: "answered", fact_ids: [], handoff_offered: false, handoff_completed: false
          )
          value = ReplyOutcome.from(hostile)

          assert_nil value.action
          assert_nil value.pending_slot
          assert_equal 9, value.clarification_count
          assert_equal %w(area_query), value.entity_keys

          receipt = ReplyOutcome.from(ConfirmedReportSubmission::Receipt.new(reference: "MI-SYNTHETIC", replayed: false))
          assert_nil receipt.action
          assert_equal 0, receipt.clarification_count
          assert_equal [], receipt.entity_keys
        end

        def test_provider_resolutions_survive_normalisation
          result = Dialogue::ProcedureRunner::Result.new(
            state: { "topic" => "unknown" }, reply: nil, resolution: "provider_unavailable",
            fact_ids: [], handoff_offered: false, handoff_completed: false
          )
          assert_equal "provider_unavailable", ReplyOutcome.from(result).dimensions.resolution
          assert_equal "busy", ReplyOutcome.from(result.with(resolution: "busy")).dimensions.resolution
        end

        def test_safety_guidance_keeps_its_type_without_inventing_a_receipt_or_grounded_answer
          result = Dialogue::ProcedureRunner::Result.new(
            state: { "topic" => "unknown" }, reply: nil, resolution: Dialogue::Resolution::SAFETY_GUIDANCE,
            fact_ids: [], handoff_offered: false, handoff_completed: false
          )
          value = ReplyOutcome.from(result)
          assert_equal "safety_guidance", value.dimensions.resolution
          refute value.dimensions.action_receipt
          refute value.dimensions.grounded_answer
          refute value.dimensions.handoff_offered
          refute value.dimensions.handoff_completed
          refute value.factual_history
        end

        def test_untyped_provider_or_request_objects_cannot_claim_submission
          [nil, { "reference" => "MI-SYNTHETIC", "replayed" => false }, "submitted",
           Struct.new(:reference, :replayed).new("MI-SYNTHETIC", false)].each do |untrusted|
            assert_nil ReplyOutcome.from(untrusted)
          end
        end
      end
    end
  end
end
