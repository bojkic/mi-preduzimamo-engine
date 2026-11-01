# frozen_string_literal: true

require "test_helper"
require "json"
require_relative "../../../../../app/services/decidim/bih/concierge/dialogue/procedure_runner"
require_relative "../../../../../app/services/decidim/bih/concierge/turn_diagnostics"

module Decidim
  module Bih
    module Concierge
      unless defined?(ConfirmedReportSubmission)
        # The real class needs Rails; the route rule only needs the receipt's shape.
        class ConfirmedReportSubmission
          Receipt = Data.define(:reference, :replayed)
        end
      end

      # One JSON line per turn for synthetic runs: bounded tokens, counts and
      # booleans only. Never citizen text, entity values, session or location.
      class TurnDiagnosticsTest < Minitest::Test
        KEYS = %w(route model_called read_count missing_field_reason transition resolution topic action ms capability_gate).freeze
        # Every value is a quoted lowercase token, null, a boolean or an integer.
        LINE = /\A\[MilicaDiag\] \{(?:"[a-z_]+":(?:"[a-z][a-z0-9_]{0,39}"|null|true|false|\d+),?){10}\}\z/

        def result(diagnostics: nil, state: { "topic" => "water" })
          Dialogue::ProcedureRunner::Result.new(state:, reply: nil, resolution: "answered", fact_ids: [], handoff_offered: false,
                                                handoff_completed: false, diagnostics:)
        end

        def diagnostics(**overrides)
          { "transition" => "start", "read_count" => 1, "missing_field_reason" => nil, "capability_gate" => "supported" }.merge(overrides.transform_keys(&:to_s))
        end

        def payload(outcome: result(diagnostics: diagnostics), model_calls: 0, resolution: "answered", topic: "water", action: "ask_information", elapsed_ms: 42) # rubocop:disable Metrics/ParameterLists
          TurnDiagnostics.payload(outcome:, model_calls:, resolution:, topic:, action:, elapsed_ms:)
        end

        def test_it_is_off_unless_the_environment_says_exactly_one
          refute TurnDiagnostics.enabled?({})
          refute TurnDiagnostics.enabled?({ "MILICA_DIAGNOSTIC" => "true" })
          refute TurnDiagnostics.enabled?({ "MILICA_DIAGNOSTIC" => "0" })
          assert TurnDiagnostics.enabled?({ "MILICA_DIAGNOSTIC" => "1" })
        end

        def test_the_payload_has_exactly_the_documented_keys_in_order
          assert_equal KEYS, payload.keys
          assert_equal KEYS, TurnDiagnostics::KEYS
        end

        def test_the_line_is_a_single_json_object_of_bounded_tokens
          line = TurnDiagnostics.line(outcome: result(diagnostics: diagnostics(missing_field_reason: "ask_area_query")), model_calls: 1,
                                      resolution: "clarification", topic: "water", action: "ask_information", elapsed_ms: 87)

          assert_match LINE, line
          parsed = JSON.parse(line.delete_prefix("[MilicaDiag] "))
          assert_equal KEYS, parsed.keys
          assert_equal({ "route" => "model", "model_called" => true, "read_count" => 1, "missing_field_reason" => "ask_area_query",
                         "transition" => "start", "resolution" => "clarification", "topic" => "water", "action" => "ask_information",
                         "ms" => 87, "capability_gate" => "supported" }, parsed)
        end

        def test_entity_values_and_free_text_never_reach_the_line
          state = { "topic" => "water", "entities" => { "query" => "Ulica Kralja Petra 12, secret 38765", "area_query" => "Dvorovi" } }
          outcome = result(state:, diagnostics: diagnostics(missing_field_reason: "Kralja Petra", transition: "Ulica"))

          line = TurnDiagnostics.line(outcome:, model_calls: 0, resolution: "clarification", topic: "water", action: "ask_information", elapsed_ms: 5)

          assert_match LINE, line
          refute_includes line, "Kralja"
          refute_includes line, "Dvorovi"
          refute_includes line, "38765"
        end

        def test_hostile_or_unknown_tokens_fall_back_to_their_defaults
          value = payload(outcome: result(diagnostics: diagnostics(transition: "teleport", capability_gate: "maybe", read_count: -3, missing_field_reason: "Bad Value")),
                          resolution: "Answered!", topic: "../etc", action: nil, elapsed_ms: -1)

          assert_equal "none", value.fetch("transition")
          assert_equal "skipped", value.fetch("capability_gate")
          assert_equal 0, value.fetch("read_count")
          assert_nil value.fetch("missing_field_reason")
          assert_equal "unknown", value.fetch("resolution")
          assert_equal "unknown", value.fetch("topic")
          assert_equal "unknown", value.fetch("action")
          assert_equal 0, value.fetch("ms")
        end

        def test_a_turn_the_procedures_answered_is_a_fast_path_without_a_model_call_and_a_model_route_with_one
          assert_equal "fast_path", payload(model_calls: 0).fetch("route")
          assert_equal "model", payload(model_calls: 1).fetch("route")
          assert_equal false, payload(model_calls: 0).fetch("model_called")
          assert_equal true, payload(model_calls: 2).fetch("model_called")
        end

        def test_a_reply_without_procedure_diagnostics_is_a_control_or_a_secondary_read
          assert_equal "control", payload(outcome: nil, model_calls: 0).fetch("route")
          assert_equal "control", payload(outcome: result(diagnostics: nil, state: nil), model_calls: 0).fetch("route")
          assert_equal "control", payload(outcome: result(diagnostics: nil), model_calls: 0).fetch("route")
          assert_equal "secondary", payload(outcome: result(diagnostics: nil), model_calls: 1).fetch("route")
          assert_equal "model", payload(outcome: result(diagnostics: nil, state: nil), model_calls: 1).fetch("route")
        end

        def test_a_report_receipt_is_the_report_wrapper_route
          receipt = ConfirmedReportSubmission::Receipt.new(reference: "MI-1", replayed: false)

          value = payload(outcome: receipt, model_calls: 1, resolution: "submitted", topic: "report", action: "report_problem")

          assert_equal "report_wrapper", value.fetch("route")
          assert_equal "skipped", value.fetch("capability_gate")
          assert_equal 0, value.fetch("read_count")
        end

        def test_an_outcome_without_a_diagnostics_reader_is_tolerated
          value = payload(outcome: Object.new, model_calls: 0)

          assert_equal "control", value.fetch("route")
          assert_equal "none", value.fetch("transition")
        end
      end
    end
  end
end
