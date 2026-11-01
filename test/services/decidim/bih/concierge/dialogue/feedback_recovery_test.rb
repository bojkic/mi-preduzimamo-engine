# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"
require_relative "../../../../../support/decidim/bih/dialogue_characterisation"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class FeedbackRecoveryTest < Minitest::Test
          WASTE = "Nije korisno, pitao sam za redovan odvoz, ne želim da prijavim problem."
          BOARD = "Nije korisno. Zanimaju me objave komšija na platformi, ne vijesti sa gradskog sajta."
          PARKING = "Označio sam Nije korisno jer još ne znam koju zonu da platim. Nemam naziv ulice, ali vidim znak za parking."

          def setup
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "f" * 64,
                                                     capabilities: ["public_reads"], now: Characterisation::NOW)
            @store = StateStore.new(redis: Characterisation::FakeRedis.new)
            @model = []
            @reads = []
          end

          def test_feedback_prefix_preserves_positive_intent_and_negative_constraint
            assert_equal "pitao sam za redovan odvoz, ne želim da prijavim problem.", TextPredicates.contrastive_correction(WASTE)["positive"]
            assert_equal "Zanimaju me objave komšija na platformi, ne vijesti sa gradskog sajta.", TextPredicates.contrastive_correction(BOARD)["positive"]
            ["Nije korisno", "Korisno, hvala.", "Šta znači Nije korisno?", "Rekla sam Nije korisno, kako dalje?"].each do |text|
              assert_nil TextPredicates.contrastive_correction(text), text
            end
          end

          def test_regular_collection_correction_keeps_only_missing_location_without_a_report
            seed("waste")
            before = @store.read(context: @context)
            result = turn(WASTE)
            assert_equal "clarification", result.resolution
            assert_includes result.reply.text, "raspored redovnog odvoza"
            assert_includes result.reply.text, "ne pokrećem prijavu"
            assert_equal before.slice(*StateStore::TASK_KEYS), result.state.slice(*StateStore::TASK_KEYS)
            assert_nil result.reply.report
            assert_empty @reads
            assert_empty @model
          end

          def test_visible_parking_sign_changes_the_requested_evidence_not_the_zone_or_charge
            seed("parking")
            before = @store.read(context: @context)
            result = turn(PARKING)
            assert_equal "clarification", result.resolution
            assert_includes result.reply.text, "oznaku ili boju zone i SMS broj"
            assert_includes result.reply.text, "ne mogu potvrditi koju zonu"
            assert_equal before.slice(*StateStore::TASK_KEYS), result.state.slice(*StateStore::TASK_KEYS)
            assert_empty result.fact_ids
            assert_empty @reads
            assert_empty @model
          end

          def test_sign_clue_declines_new_locations_mixed_tasks_negation_and_private_work
            seed("parking")
            state = @store.read(context: @context)
            ["Ne vidim znak za parking", "Vidim znak za parking i prijavi problem", "Vidim znak za parking u Svetog Save"].each do |text|
              assert_nil direct_recovery(text, state), text
            end
            [{ "active_task" => "report_problem", "topic" => "report" }, { "topic" => "account" },
             { "draft" => { "opaque_ref" => "a" * 32 } }, { "pending_slot" => "description" }].each do |change|
              assert_nil direct_recovery(PARKING, state.merge(change))
            end
            @context = @context.with(capabilities: ["own_report_reads"], actor_id: 7, account_state: "verified")
            assert_nil direct_recovery(PARKING, state)
          end

          def test_a_new_photo_or_precise_location_keeps_the_evidence_processing_path
            seed("parking")
            state = @store.read(context: @context)
            [Struct.new(:image_url).new("https://example.org/parking-sign.png"),
             Struct.new(:dialogue_location).new({ "latitude" => 44.75, "longitude" => 19.21 }),
             Struct.new(:latitude).new(44.75)].each do |message|
              assert_nil direct_recovery(PARKING, state, message:)
            end
          end

          def test_neighborhood_post_correction_uses_existing_private_authorization
            seed("neighborhood")
            anonymous = turn(BOARD)
            assert_equal "handoff", anonymous.resolution
            assert_equal "neighborhood_information", @reads.last.fetch(:action)
            assert_nil @reads.last.fetch(:context).actor_id
            refute @reads.last.fetch(:context).allows?("neighborhood_reads"), "the read adapter receives no invented membership"
            assert_empty anonymous.fact_ids
            @reads.clear
            assert_empty @model

            @context = @context.with(actor_id: 7, account_state: "verified", capabilities: %w(public_reads neighborhood_reads))
            @store = StateStore.new(redis: Characterisation::FakeRedis.new)
            seed("neighborhood")
            authorized = turn(BOARD)
            assert_equal "handoff", authorized.resolution, "the actual reader still denies an unconfirmed membership"
            assert_equal "neighborhood_information", @reads.last.fetch(:action)
            assert_equal @context, @reads.last.fetch(:context).with(deadline: nil)
            assert_includes @reads.last.fetch(:entities).fetch("query"), "objave komšija"
            assert_empty @model
          end

          def test_board_route_declines_negation_public_news_and_write_commands
            ["Ne želim objave komšija na platformi", "Objavi poruku komšijama na platformi",
             "Zanimaju me vijesti sa gradskog sajta", "Zanimaju me objave komšija na platformi i pošalji prijavu"].each do |text|
              refute_equal "neighborhood_information", CivicQuestion.classify(text)&.fetch(:action), text
            end
          end

          def test_safety_and_draft_precedence_are_preserved
            seed("waste")
            result = turn("Nije korisno. Gori mi kuća!")
            assert_equal "safety_guidance", result.resolution
            assert_empty @model
            assert_empty @reads
            state = @store.empty_state(@context).merge("active_task" => "report_problem", "topic" => "report", "pending_slot" => "description")
            coordinator = Coordinator.new(understanding: ->(**) { raise "unused" }, procedures: Object.new)
            assert_nil coordinator.send(:correction_question, Characterisation::Message.new(text: WASTE, conversation_context: [], dialogue_location: nil), state)
            assert_nil coordinator.send(:correction_question, Characterisation::Message.new(text: BOARD, conversation_context: [], dialogue_location: nil),
                                        state.merge("active_task" => "ask_information", "draft" => { "opaque_ref" => "a" * 32 }))
          end

          private

          def seed(topic)
            state = @store.empty_state(@context).merge("active_task" => "ask_information", "topic" => topic, "pending_slot" => "area_query", "clarification_count" => 1)
            assert_equal :saved, @store.write(context: @context, state:, expected_version: 0)
          end

          def direct_recovery(text, state, message: nil)
            turn = Struct.new(:text, :state, :context, :message) { def cancelled? = false }.new(text, state, @context, message)
            FeedbackRecoveryStage.result_for(turn)
          end

          def turn(text)
            Characterisation.with_locales do
              coordinator = Coordinator.new(
                understanding: lambda { |**args|
                  @model << args
                  raise "Unexpected model call"
                },
                procedures: ProcedureRunner.new(read_port: lambda { |**args|
                  @reads << args
                  Contracts::ReadResult.new(status: "not_authorized")
                }, registration_port: ->(**) { raise "Unexpected account operation" }, destinations: Characterisation::DESTINATIONS),
                state_store: @store, runtime: Characterisation::InlineRuntime.new
              )
              coordinator.call(message: Characterisation::Message.new(text:, conversation_context: [], dialogue_location: nil), context: @context)
            end
          end
        end
      end
    end
  end
end
