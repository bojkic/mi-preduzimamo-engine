# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/procedure_runner"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # A host capability inventory handed to the runner decides, before any
        # slot is collected, whether a topic has a reader or a reviewed source
        # family. Without one the runner behaves exactly as before. Every
        # result also carries bounded per-turn diagnostics for synthetic runs.
        class CapabilityGateTest < Minitest::Test
          NOW = Time.utc(2026, 9, 13, 12)
          Message = Data.define(:text, :dialogue_location)
          Capabilities = Struct.new(:supported, :next_step) do
            def supported?(topic) = supported.include?(topic)

            def next_step_for(_topic) = next_step
          end
          DESTINATIONS = { report: "/mi/prijavi", account: "/mi/moj-nalog", neighborhood: "/mi/komsiluk", support: "/pages/pomoc" }.freeze

          def setup
            I18n.available_locales = Contracts::LOCALES
            I18n.load_path += [File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__)]
            I18n.backend.reload!
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "a" * 64, now: NOW, capabilities: %w(public_reads report_guidance registration_handoff))
            @state = StateStore.new.empty_state(@context)
            @reads = []
            @read_result = Contracts::ReadResult.new(status: "empty")
          end

          def runner(capabilities: :none)
            options = { read_port: lambda { |**args|
                                     @reads << args
                                     @read_result
                                   },
                        registration_port: ->(**) { raise "no handoff expected" },
                        destinations: DESTINATIONS }
            options[:capabilities] = capabilities unless capabilities == :none
            ProcedureRunner.new(**options)
          end

          def run_turn(runner, text, topic:, action: "ask_information", entities: {}, operation: "start", locale: "sr") # rubocop:disable Metrics/ParameterLists
            understanding = Contracts::Understanding.parse(action:, topic:, entities:, operation:, locale:, needs_clarification: false, secondary: nil)
            result = runner.call(understanding:, state: @state, context: @context, message: Message.new(text:, dialogue_location: nil))
            @state = result.state
            result
          end

          def test_an_unsupported_topic_gets_the_unsupported_copy_with_the_next_step_and_no_slot_question
            capabilities = Capabilities.new(%w(waste parking), "https://community.example.invalid/authored-pharmacy-source")

            result = run_turn(runner(capabilities:), "ima li dezurna apoteka nocas", topic: "weather", entities: { time_expression: "noćas" })

            assert_equal "unsupported", result.resolution
            assert_equal I18n.t("decidim.bih.dialogue.unsupported_topic", locale: "sr", next_step: "https://community.example.invalid/authored-pharmacy-source"), result.reply.text
            assert_equal "service", result.reply.answer_intent
            assert_nil @state["pending_slot"], "an unsupported topic must not leave a slot question pending"
            assert_empty @reads, "the gate runs before any read"
            assert_equal false, result.handoff_offered
          end

          def test_the_unsupported_copy_never_asks_for_a_day_or_a_place_in_any_locale
            capabilities = Capabilities.new([], "/pages/pomoc")
            Contracts::LOCALES.each do |locale|
              @state = StateStore.new.empty_state(@context)
              result = run_turn(runner(capabilities:), "pharmacy tonight", topic: "weather", locale:)

              assert_equal "unsupported", result.resolution, locale
              limit = result.reply.text.sub(/(?:korak|корак|step): .*\z/m, "")
              refute_match(/dan|vrijeme|mjesto|day|time|place|дан|вријеме|мјесто/i, limit, locale)
            end
          end

          def test_a_next_step_that_is_neither_a_safe_url_nor_a_phone_falls_back_to_the_support_destination
            capabilities = Capabilities.new([], "javascript:alert(1)")

            result = run_turn(runner(capabilities:), "apoteka", topic: "weather")

            assert_equal I18n.t("decidim.bih.dialogue.unsupported_topic", locale: "sr", next_step: "/pages/pomoc"), result.reply.text
          end

          def test_a_reviewed_phone_number_is_an_acceptable_next_step
            capabilities = Capabilities.new([], "+1 202 555 0101")

            result = run_turn(runner(capabilities:), "apoteka", topic: "weather")

            assert_includes result.reply.text, "+1 202 555 0101"
          end

          def test_a_collaborator_without_next_step_for_uses_the_support_destination
            only_supported = Object.new
            def only_supported.supported?(_topic) = false

            result = run_turn(runner(capabilities: only_supported), "apoteka", topic: "weather")

            assert_equal "unsupported", result.resolution
            assert_includes result.reply.text, "/pages/pomoc"
          end

          def test_a_supported_topic_still_asks_for_the_area_when_it_needs_one
            capabilities = Capabilities.new(%w(water), "/pages/pomoc")

            result = run_turn(runner(capabilities:), "ima li vode", topic: "water")

            assert_equal "clarification", result.resolution
            assert_equal "area_query", @state["pending_slot"]
            assert_equal I18n.t("decidim.bih.dialogue.ask_area_query", locale: "sr"), result.reply.text
          end

          def test_an_unknown_topic_keeps_the_clarification
            capabilities = Capabilities.new([], "/pages/pomoc")

            result = run_turn(runner(capabilities:), "hm", topic: "unknown")

            assert_equal "clarification", result.resolution
            assert_equal I18n.t("decidim.bih.dialogue.clarify", locale: "sr"), result.reply.text
          end

          def test_without_a_collaborator_the_topic_is_read_as_before
            result = run_turn(runner, "kakvo je vrijeme", topic: "weather")

            assert_equal 1, @reads.length
            # The fixture read carries no facts, so the turn ends with the "no verified
            # data" refusal. That is "unsupported", not "answered" (Task 9b).
            assert_equal "unsupported", result.resolution
            assert_equal "skipped", result.diagnostics.fetch("capability_gate")
          end

          def test_diagnostics_describe_the_refused_turn_without_any_citizen_text
            capabilities = Capabilities.new([], "/pages/pomoc")

            result = run_turn(runner(capabilities:), "ima li dezurna apoteka nocas", topic: "weather", entities: { time_expression: "noćas" })

            # Task 4 extends this with the bounded fields the failure trace
            # asked for: entity KEY NAMES (never values), the read family's
            # status and warning COUNT, the render path and the facet token.
            assert_equal({ "transition" => "start", "read_count" => 0, "missing_field_reason" => nil, "capability_gate" => "unsupported",
                           "supplied_entity_keys" => ["time_expression"], "retained_entity_keys" => [], "dropped_entity_keys" => [],
                           "read_status" => nil, "read_warning_codes" => 0, "render_path" => "none", "facet" => nil,
                           "draft_replaced" => false }, result.diagnostics)
            assert result.diagnostics.frozen?
          end

          def test_diagnostics_describe_a_clarification_and_a_read
            capabilities = Capabilities.new(%w(water), "/pages/pomoc")
            first = run_turn(runner(capabilities:), "ima li vode", topic: "water")

            assert_equal({ "transition" => "start", "read_count" => 0, "missing_field_reason" => "ask_area_query", "capability_gate" => "supported",
                           "supplied_entity_keys" => [], "retained_entity_keys" => [], "dropped_entity_keys" => [],
                           "read_status" => nil, "read_warning_codes" => 0, "render_path" => "clarify", "facet" => nil,
                           "draft_replaced" => false }, first.diagnostics)

            second = run_turn(runner(capabilities:), "u Testnom vrtu", topic: "water", entities: { area_query: "Testni vrt" }, operation: "continue")

            assert_equal "continue", second.diagnostics.fetch("transition")
            assert_equal 1, second.diagnostics.fetch("read_count")
            assert_nil second.diagnostics.fetch("missing_field_reason")
          end

          def test_a_cancellation_is_a_cancel_transition
            run_turn(runner, "ima li vode", topic: "water")
            result = run_turn(runner, "odustani", topic: "unknown", action: "cancel", operation: "cancel")

            assert_equal "cancelled", result.resolution
            assert_equal "cancel", result.diagnostics.fetch("transition")
          end

          def test_a_result_built_without_diagnostics_still_constructs
            result = ProcedureRunner::Result.new(state: nil, reply: nil, resolution: "busy", fact_ids: [], handoff_offered: false, handoff_completed: false)

            assert_nil result.diagnostics
          end
        end
      end
    end
  end
end
