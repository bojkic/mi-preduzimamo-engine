# frozen_string_literal: true

require "test_helper"
require "yaml"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/procedure_runner"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Real semantic transitions with synthetic typed reads. The host's
        # existing volunteer catalogue still owns recurrence/category/calendar.
        class PublicActivityContinuationTest < Minitest::Test
          def setup
            @old_backend = I18n.backend
            @old_locales = I18n.available_locales
            I18n.backend = I18n::Backend::Simple.new
            I18n.available_locales = Contracts::LOCALES
            I18n.backend.load_translations(File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__))
            @context = Contracts::TrustedContext.new(organization_id: 71, conversation_key: "f" * 64,
                                                     now: Time.utc(2026, 9, 9, 12), capabilities: ["public_reads"])
            @reads = []
            @read_result = Contracts::ReadResult.new(status: "empty")
            @port = lambda do |**args|
              @reads << args
              @read_result
            end
            @destinations = { report: "/prijavi", account: "/nalog", neighborhood: "/komsiluk", support: "/pomoc" }
            @runner = ProcedureRunner.new(read_port: @port, registration_port: ->(**) { raise "Unexpected account action" }, destinations: @destinations)
          end

          def teardown
            I18n.backend = @old_backend
            I18n.available_locales = @old_locales
          end

          def test_closed_volunteer_followup_preserves_citizen_area_time_and_existing_suspension_across_model_switch
            %w(neighborhood participation).product(%w(start switch continue)).each do |topic, operation|
              prime(topic:)
              saved = StateStore.new.empty_state(@context).slice(*StateStore::TASK_KEYS).merge("active_task" => "registration", "topic" => "account")
              @state["suspended_task"] = saved
              result = turn("A neke volonterske akcije?", operation:)
              # The fixture read carries no facts, so the turn ends with the "no verified
              # data" refusal. That is "unsupported", not "answered" (Task 9b).
              assert_equal "unsupported", result.resolution
              assert_equal "volunteer", @reads.last[:topic]
              assert_equal "ask_information", @reads.last[:action]
              assert_equal "MZ Dvorovi", @reads.last.dig(:entities, "area_query")
              assert_equal "uskoro", @reads.last.dig(:entities, "time_expression")
              assert_equal "A neke volonterske akcije?", @reads.last.dig(:entities, "query")
              assert_equal saved, result.state["suspended_task"]
              assert_equal "citizen", result.state.dig("entity_provenance", "area_query")
              assert_equal false, @reads.last[:context].allows?("neighborhood_reads")
            end
          end

          def test_unsupported_time_is_not_dropped_and_calendar_correction_keeps_place
            prime(time: "sljedeceg mjeseca")
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["unsupported_catalog_time"])
            result = turn("A neke volonterske akcije?")
            assert_equal "clarification", result.resolution
            assert_equal "time_expression", result.state["pending_slot"]
            assert_equal "sljedeceg mjeseca", @reads.last.dig(:entities, "time_expression")
            assert_equal "MZ Dvorovi", result.state.dig("entities", "area_query")

            @read_result = Contracts::ReadResult.new(status: "empty")
            result = turn("Ovog vikenda", operation: "continue", entities: { "time_expression" => "ovog vikenda" })
            assert_equal "unsupported", result.resolution
            assert_equal "ovog vikenda", @reads.last.dig(:entities, "time_expression")
            assert_equal "MZ Dvorovi", @reads.last.dig(:entities, "area_query")
          end

          def test_named_new_place_uses_normal_switch_without_old_calendar_or_area
            prime
            result = turn("A volonterske akcije u Janji?", entities: { "area_query" => "MZ Janja" })
            assert_equal "MZ Janja", @reads.last.dig(:entities, "area_query")
            assert_nil @reads.last.dig(:entities, "time_expression")
            assert_equal "volunteer", result.state["topic"]
          end

          def test_unrelated_previous_topic_does_not_inherit_area
            prime(topic: "transport")
            turn("A neke volonterske akcije?")
            assert_nil @reads.last.dig(:entities, "area_query")
            assert_nil @reads.last.dig(:entities, "time_expression")
          end

          def test_draft_board_and_profile_scope_are_not_reinterpreted
            cases = [
              { state: { "draft" => {} } },
              { query: "Volonterske akcije na tabli komšiluka" },
              { provenance: "trusted_profile" }
            ]
            cases.each do |example|
              prime
              @state.merge!(example.fetch(:state, {}))
              @state["entities"]["query"] = example[:query] if example[:query]
              @state["entity_provenance"]["area_query"] = example[:provenance] if example[:provenance]
              input = understanding(entities: example.fetch(:entities, {}), secondary: example[:secondary])
              actor = ProcedureRunner::Turn.new(read_port: @port, registration_port: nil, destinations: @destinations, state: @state,
                                                context: @context, message: "A neke volonterske akcije?", understanding: input)
              assert_equal false, actor.send(:public_activity_follow_up?), example.inspect
              assert_equal input, actor.send(:understanding)
            end
            assert_empty @reads
          end

          def test_exact_citizen_followup_ignores_model_invented_place_and_time
            prime
            @state["entities"]["query"] = "Javna ponuda"
            result = turn("A neke volonterske akcije?", entities: { "area_query" => "MZ Janja", "time_expression" => "sutra" })
            assert_equal "unsupported", result.resolution
            assert_equal "MZ Dvorovi", @reads.last.dig(:entities, "area_query")
            assert_equal "uskoro", @reads.last.dig(:entities, "time_expression")
            assert_equal "volunteer", @reads.last[:topic]
          end

          private

          def prime(topic: "neighborhood", time: "uskoro")
            @state = StateStore.new.empty_state(@context)
            @state.merge!("active_task" => "ask_information", "topic" => topic,
                          "entities" => { "query" => "Ima li javnih okupljanja u MZ Dvorovi?", "area_query" => "MZ Dvorovi", "time_expression" => time },
                          "entity_provenance" => { "query" => "citizen", "area_query" => "citizen", "time_expression" => "citizen" })
          end

          def understanding(operation: "switch", entities: {}, secondary: nil)
            Contracts::Understanding.parse(action: "ask_information", topic: "volunteer", operation:, entities:,
                                            needs_clarification: false, secondary:, locale: "sr")
          end

          def turn(text, operation: "switch", entities: {})
            result = @runner.call(understanding: understanding(operation:, entities:), state: @state, context: @context, message: text)
            @state = result.state
            result
          end
        end
      end
    end
  end
end
