# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/public_activity_continuation"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/procedure_runner"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class PublicActivityScopeRefinementTest < Minitest::Test
          def setup
            @old_backend = I18n.backend
            @old_locales = I18n.available_locales
            I18n.backend = I18n::Backend::Simple.new
            I18n.available_locales = Contracts::LOCALES
            I18n.backend.load_translations(File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__))
            @context = Contracts::TrustedContext.new(organization_id: 71, conversation_key: "e" * 64,
                                                     now: Time.utc(2026, 9, 10, 12), capabilities: ["public_reads"])
            @state = StateStore.new.empty_state(@context).merge(
              "active_task" => "ask_information", "topic" => "volunteer",
              "entities" => { "query" => "Javna ponuda", "area_query" => "Komšiluk Dvorovi", "category" => "environment", "date" => "2026-09-12" },
              "entity_provenance" => { "query" => "citizen", "area_query" => "citizen", "category" => "citizen", "date" => "citizen" }
            )
            @reads = []
            @runner = ProcedureRunner.new(read_port: lambda { |**args|
              @reads << args
              Contracts::ReadResult.new(status: "empty")
            },
                                          registration_port: ->(**) { raise "Unexpected account operation" },
                                          destinations: { report: "/prijavi", account: "/nalog", neighborhood: "/komsiluk", support: "/pomoc" })
          end

          def teardown
            I18n.backend = @old_backend
            I18n.available_locales = @old_locales
          end

          def test_qualified_correction_keeps_citizen_kind_and_current_public_topic
            { "Ne, mislim na MZ Dvorovi" => "MZ Dvorovi", "Mislim na komšiluk Dvorovi." => "komšiluk Dvorovi",
              "Не, мислим на МЗ Дворови" => "МЗ Дворови", "No, I mean MZ Dvorovi" => "MZ Dvorovi" }.each do |text, area|
              input = refine(text)
              assert_equal "correct", input.operation
              assert_equal "volunteer", input.topic
              assert_equal({ "area_query" => area }, input.entities)
              assert_equal false, input.needs_clarification
            end
          end

          def test_area_correction_uses_real_transition_to_remove_old_geography_without_dropping_calendar_or_category
            @state["entities"].merge!("area_slug" => "komsiluk-55", "street" => "Old street", "address" => "Old address")
            @state["entity_provenance"].merge!("area_slug" => "citizen", "street" => "citizen", "address" => "citizen")
            saved = StateStore.new.empty_state(@context).slice(*StateStore::TASK_KEYS).merge("active_task" => "report_problem", "topic" => "report")
            @state["suspended_task"] = saved
            result = turn("Ne, mislim na MZ Dvorovi")
            # The fixture read carries no facts, so the turn ends with the "no verified
            # data" refusal. That is "unsupported", not "answered" (Task 9b).
            assert_equal "unsupported", result.resolution
            assert_equal "MZ Dvorovi", @reads.last.dig(:entities, "area_query")
            %w(area_slug street address).each { |key| assert_nil @reads.last.dig(:entities, key) }
            assert_equal "2026-09-12", @reads.last.dig(:entities, "date")
            assert_equal "environment", @reads.last.dig(:entities, "category")
            assert_equal "corrected", result.state.dig("entity_provenance", "area_query")
            assert_equal saved, result.state["suspended_task"]
          end

          def test_day_and_weekend_followups_preserve_topic_and_invalidate_only_old_date
            { "A sljedećeg vikenda?" => "sljedeceg vikenda", "А сљедећег викенда?" => "sljedeceg vikenda",
              "A sutra?" => "sutra", "And next weekend?" => "next weekend" }.each do |text, expression|
              result = turn(text)
              assert_equal "unsupported", result.resolution
              assert_equal expression, @reads.last.dig(:entities, "time_expression")
              assert_nil @reads.last.dig(:entities, "date")
              assert_equal "Komšiluk Dvorovi", @reads.last.dig(:entities, "area_query")
              assert_equal "environment", @reads.last.dig(:entities, "category")
              assert_equal "Javna ponuda", @reads.last.dig(:entities, "query")
              assert_equal "volunteer", @reads.last[:topic]
            end
          end

          def test_pending_calendar_answer_and_all_public_activity_topics_are_typed_without_mutating_state
            @state["pending_slot"] = "time_expression"
            %w(neighborhood participation volunteer community).each do |topic|
              @state["topic"] = topic
              before = Marshal.dump(@state)
              input = refine("Ovog vikenda")
              assert_equal topic, input.topic
              assert_equal({ "time_expression" => "ovog vikenda" }, input.entities)
              assert_equal before, Marshal.dump(@state)
            end
          end

          def test_private_draft_and_unrelated_tasks_are_not_refined
            [@state.merge("active_task" => "report_problem"), @state.merge("topic" => "transport"), @state.merge("draft" => {}),
             @state.merge("prior_evidence" => { "kind" => "member_board" }),
             @state.merge("entities" => @state["entities"].merge("query" => "Objave na tabli"))].each do |state|
              assert_nil refine("A sljedećeg vikenda?", state:)
              assert_nil refine("Ne, mislim na MZ Dvorovi", state:)
            end
            @state["entity_provenance"]["area_query"] = "trusted_profile"
            assert_nil refine("A sutra?")
          end

          def test_mixed_requests_new_unqualified_scope_and_unknown_time_stay_with_normal_understanding
            ["Ne, mislim na Dvorovi", "Ne, mislim na MZ Dvorovi i Janja", "Ne, mislim na MZ Dvorovi sutra",
             "Ne, mislim na MZ <b>Dvorovi</b>", "A sljedećeg vikenda u Janji?", "A sutra i prijavi problem", "A sljedećeg mjeseca?", "Sljedećeg vikenda"].each do |text|
              assert_nil refine(text), text
            end
          end

          private

          def refine(text, state: @state)
            PublicActivityContinuation.call(text:, state:, locale: "sr")
          end

          def turn(text)
            @runner.call(understanding: refine(text), state: @state, context: @context, message: text)
          end
        end
      end
    end
  end
end
