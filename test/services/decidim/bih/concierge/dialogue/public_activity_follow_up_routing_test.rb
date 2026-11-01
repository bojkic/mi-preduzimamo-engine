# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Actual Coordinator -> fast understanding -> procedures -> CAS flow.
        # Synthetic public reads only: no model, Redis server or Rails/DB boot.
        class PublicActivityFollowUpRoutingTest < Minitest::Test
          class MemoryRedis
            def initialize = @data = {}

            def get(key) = @data[key]

            def eval(script, keys:, argv:)
              raise "Unexpected persistence" unless script == StateStore::WRITE_SCRIPT

              old = @data[keys.first]
              return 0 unless (old ? JSON.parse(old).fetch("version") : 0) == argv.first

              @data[keys.first] = argv[1]
              1
            end
          end

          class InlineRuntime
            # These assertions cover routing, not machine speed. Budget expiry is
            # exercised separately in TurnBudgetTest; keep CPU contention from
            # turning a valid routing result into a context-unavailable fallback.
            def call = AdmissionControl::Result.new(status: :admitted, value: yield(TurnBudget.new(timeout: 2, clock: -> { 0.0 })))
          end

          def setup
            @old_backend = I18n.backend
            @old_locales = I18n.available_locales
            I18n.backend = I18n::Backend::Simple.new
            I18n.available_locales = Contracts::LOCALES
            I18n.backend.load_translations(File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__))
            @context = Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64,
                                                     now: Time.utc(2026, 9, 9, 12), capabilities: ["public_reads"])
            @reads = []
            @model_calls = 0
            @read_result = Contracts::ReadResult.new(status: "ambiguous", candidates: [
                                                       { "slug" => "mz-dvorovi", "kind" => "mz", "label" => "Dvorovi" },
                                                       { "area_slug" => "komsiluk-55", "area_kind" => "komsiluk", "text" => "Dvorovi" }
                                                     ], warnings: ["area_name_ambiguous"])
            @store = StateStore.new(redis: MemoryRedis.new)
            procedures = ProcedureRunner.new(read_port: lambda { |**args|
              @reads << args
              @read_result
            },
                                             registration_port: ->(**) { raise "Unexpected account action" },
                                             destinations: { report: "/prijavi", account: "/nalog", neighborhood: "/komsiluk", support: "/pomoc" })
            @coordinator = Coordinator.new(procedures:, state_store: @store, runtime: InlineRuntime.new,
                                           understanding: lambda { |**|
                                             @model_calls += 1
                                             raise "Closed follow-up reached model"
                                           })
          end

          def teardown
            I18n.backend = @old_backend
            I18n.available_locales = @old_locales
          end

          def test_live_like_volunteer_followup_and_qualified_choice_bypass_model_with_paraphrased_prior_query
            seed
            followup = @coordinator.call(message: "A neke volonterske akcije?", context: @context)
            assert_equal "clarification", followup.resolution, followup.reply.text
            assert_equal "volunteer", @reads.last[:topic]
            assert_equal "Dvorovima", @reads.last.dig(:entities, "area_query")
            assert_equal "uskoro", @reads.last.dig(:entities, "time_expression")
            assert_includes followup.reply.text, "komšiluk Dvorovi or local community (MZ) Dvorovi"
            assert_equal "volunteer", @store.read(context: @context)["topic"]

            @read_result = Contracts::ReadResult.new(status: "empty")
            chosen = @coordinator.call(message: "Komšiluk Dvorovi", context: @context)
            # The fixture read carries no facts, so the turn ends with the "no verified
            # data" refusal. That is "unsupported", not "answered" (Task 9b).
            assert_equal "unsupported", chosen.resolution
            assert_equal "Komšiluk Dvorovi", @reads.last.dig(:entities, "area_query")
            assert_equal "uskoro", @reads.last.dig(:entities, "time_expression")
            assert_equal "volunteer", @reads.last[:topic]
            assert_equal "A neke volonterske akcije?", @reads.last.dig(:entities, "query")
            assert_equal 0, @model_calls
            assert_equal 2, @reads.length
          end

          def test_explicit_mz_choice_and_cyrillic_qualifier_remain_exact_during_pending_public_read
            %w(neighborhood participation volunteer).product(["MZ Dvorovi", "Комшилук Дворови"]).each do |topic, text|
              @store = StateStore.new(redis: MemoryRedis.new)
              @coordinator.instance_variable_set(:@state_store, @store)
              seed(topic:)
              @read_result = Contracts::ReadResult.new(status: "empty")
              result = @coordinator.call(message: text, context: @context)
              assert_equal "unsupported", result.resolution
              assert_equal text, @reads.last.dig(:entities, "area_query")
              assert_equal topic, @reads.last[:topic]
              assert_equal "uskoro", @reads.last.dig(:entities, "time_expression")
            end
            assert_equal 0, @model_calls
          end

          def test_private_or_new_scope_is_not_a_closed_public_followup
            seed
            state = @store.read(context: @context)
            [state.merge("active_task" => "neighborhood_information"), state.merge("draft" => {}),
             state.merge("prior_evidence" => { "kind" => "member_board" })].each do |other|
              assert_nil ProcedureRunner.public_activity_continuation_input(text: "A neke volonterske akcije?", state: other, locale: "sr")
              assert_nil ProcedureRunner.public_activity_continuation_input(text: "Komšiluk Dvorovi", state: other, locale: "sr")
            end
            ["A volonterske akcije u Janji?", "A volonterske akcije i autobus?", "MZ Dvorovi i prijavi problem", "Komšiluk Dvorovi sutra"].each do |text|
              assert_nil ProcedureRunner.public_activity_continuation_input(text:, state:, locale: "sr")
            end
          end

          def test_original_typed_place_survives_model_paraphrase_and_the_next_calendar_turn
            cases = {
              "Koje volonterske akcije ima u komšiluku Dvorovi ovog vikenda?" => "komsiluk dvorovi",
              "Koje volonterske akcije ima u MZ Dvorovi ovog vikenda?" => "mz dvorovi",
              "Које волонтерске акције има у комшилуку Дворови овог викенда?" => "komsiluk dvorovi",
              "Any volunteer activities in MZ Dvorovi this weekend?" => "mz dvorovi"
            }
            cases.each do |question, area|
              @store = StateStore.new(redis: MemoryRedis.new)
              @coordinator.instance_variable_set(:@state_store, @store)
              @model_calls = 0
              input = public_start
              @coordinator.instance_variable_set(:@understanding, lambda { |**|
                @model_calls += 1
                input
              })
              @read_result = Contracts::ReadResult.new(status: "empty")
              first = @coordinator.call(message: question, context: @context)
              assert_equal "unsupported", first.resolution
              assert_equal area, @reads.last.dig(:entities, "area_query")
              assert_equal input.entities.merge("area_query" => area), @reads.last.fetch(:entities)
              assert_equal area, @store.read(context: @context).dig("entities", "area_query")
              assert_equal "citizen", first.state.dig("entity_provenance", "area_query")

              following = @coordinator.call(message: "A sljedećeg vikenda?", context: @context)
              assert_equal "unsupported", following.resolution
              assert_equal area, @reads.last.dig(:entities, "area_query")
              assert_equal area, @store.read(context: @context).dig("entities", "area_query")
              assert_equal "sljedeceg vikenda", @reads.last.dig(:entities, "time_expression")
              assert_equal input.entities.fetch("query"), @reads.last.dig(:entities, "query")
              assert_equal "environment", @reads.last.dig(:entities, "category")
              assert_equal 1, @model_calls
              assert_equal 2, @store.read(context: @context).fetch("version")
              assert_nil following.reply.report

              corrected = @coordinator.call(message: "Ne, mislim na MZ Dvorovi", context: @context)
              assert_equal "unsupported", corrected.resolution
              assert_equal "MZ Dvorovi", @store.read(context: @context).dig("entities", "area_query")
              assert_equal "corrected", corrected.state.dig("entity_provenance", "area_query")
              assert_equal "sljedeceg vikenda", @reads.last.dig(:entities, "time_expression")
              assert_equal input.entities.fetch("query"), @reads.last.dig(:entities, "query")
              assert_equal "environment", @reads.last.dig(:entities, "category")
              assert_equal 1, @model_calls
            end
          end

          def test_original_place_restoration_never_replaces_typed_scope_or_runs_on_followups_drafts_boards_or_location
            question = "Koje volonterske akcije ima u komšiluku Dvorovi ovog vikenda?"
            @read_result = Contracts::ReadResult.new(status: "empty")
            base = StateStore.new.empty_state(@context).merge("active_task" => "ask_information", "topic" => "volunteer")
            draft = { "reference" => "opaque-fixture-123", "revision" => 1, "expires_at" => @context.now.to_f + 60 }
            board = base.merge("entities" => { "query" => "Objave na tabli komšiluka" }, "entity_provenance" => { "query" => "citizen" })
            located = Struct.new(:text, :dialogue_location).new(question, { "latitude" => 44.7, "longitude" => 19.2 })
            variants = [[base, public_start(operation: "continue"), question], [base.merge("draft" => draft), public_start, question],
                        [board, public_start, question], [base, public_start, located],
                        [base, public_start(entities: { "area_query" => "MZ Janja" }), question],
                        [base, public_start(entities: { "area_slug" => "mz-dvorovi" }), question],
                        [base, public_start(entities: { "street" => "Street already supplied" }), question]]
            runner = @coordinator.instance_variable_get(:@procedures)
            variants.each do |state, input, message|
              answer = runner.call(understanding: input, state:, context: @context, message:)
              refute_equal "komsiluk dvorovi", answer.state.dig("entities", "area_query")
              assert_equal input.entities.fetch("query"), answer.state.dig("entities", "query")
            end
          end

          def test_literal_place_parser_requires_same_bare_name_and_an_unambiguous_public_sentence
            ["Ima li okupljanja u Dvorovima ovog vikenda?", "Ima li okupljanja ne u MZ Dvorovi ovog vikenda?",
             "Ima li okupljanja u MZ Dvorovi i Janji?", "Ima li objava na tabli u MZ Dvorovi?",
             "Ima li okupljanja u MZ Dvorovi prvog vikenda?", "Ne, mislim na MZ Dvorovi", "A sljedećeg vikenda?"].each do |text|
              assert_nil PublicActivityPlace.call(text:, supplied: "Dvorovi"), text
            end
            question = "Ima li okupljanja u MZ Dvorovi sljedećeg vikenda?"
            assert_equal "mz dvorovi", PublicActivityPlace.call(text: question, supplied: nil)
            assert_nil PublicActivityPlace.call(text: question, supplied: "MZ Janja")
            assert_nil PublicActivityPlace.call(text: question, supplied: "Komšiluk Dvorovi")
          end

          private

          def public_start(operation: "start", entities: {})
            Contracts::Understanding.parse(action: "ask_information", topic: "volunteer", operation:,
                                           entities: { "query" => "Volonterske aktivnosti u Dvorovima", "area_query" => "Dvorovi",
                                                       "category" => "environment", "time_expression" => "ovog vikenda" }.merge(entities),
                                           needs_clarification: false, secondary: nil, locale: "sr")
          end

          def seed(topic: "neighborhood")
            state = StateStore.new.empty_state(@context).merge(
              "active_task" => "ask_information", "topic" => topic, "pending_slot" => "area_query",
              "entities" => { "query" => "Javna ponuda", "area_query" => "Dvorovima", "time_expression" => "uskoro" },
              "entity_provenance" => { "query" => "citizen", "area_query" => "citizen", "time_expression" => "citizen" }
            )
            assert_equal :saved, @store.write(context: @context, state:, expected_version: 0)
          end
        end
      end
    end
  end
end
