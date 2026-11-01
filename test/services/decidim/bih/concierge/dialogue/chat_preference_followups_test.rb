# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"
require_relative "../../../../../support/decidim/bih/dialogue_characterisation"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class ChatPreferenceFollowupsTest < Minitest::Test
          def setup
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "e" * 64,
                                                     capabilities: ["public_reads"], now: Characterisation::NOW)
            @store = StateStore.new(redis: Characterisation::FakeRedis.new)
            @model = []
            @reads = []
          end

          def test_registration_keeps_safety_and_report_guidance_before_location_preference
            names = PreModelStages.stage_names
            assert_operator names.index("report_guidance_card"), :<, names.index("transport_location_preference")
            assert_operator names.index("transport_location_preference"), :<, names.index("public_information_follow_up")
          end

          def test_refusing_gps_preserves_the_pending_origin_without_another_clarification_charge
            ["Ne želim slati GPS. Šta još mogu napisati?", "Ne želim dijeliti trenutnu lokaciju",
             "Не желим слати GPS. Шта још могу написати?",
             "Ne mogu poslati GPS. Mogu li napisati gdje se nalazim?",
             "Ne mogu dijeliti lokaciju. Mogu li navesti adresu?",
             "Не могу слати локацију. Могу ли написати гдје сам?",
             "I cannot share my location. Can I write my address?"].each do |message|
              seed_transport
              before = @store.read(context: @context)
              result = turn(message)
              assert_equal "clarification", result.resolution
              assert_match(/(?:GPS|ГПС) (?:nije|није)|GPS is not/, result.reply.text)
              assert_equal before.slice(*StateStore::TASK_KEYS), result.state.slice(*StateStore::TASK_KEYS)
              assert_equal 1, result.state.fetch("clarification_count")
              assert_empty @model
              assert_empty @reads
              assert_empty result.fact_ids
              assert_nil result.reply.report
              refute result.handoff_offered
            end
          end

          def test_refusal_stage_declines_new_tasks_private_context_drafts_and_mixed_requests
            message = "Ne želim slati GPS. Šta još mogu napisati?"
            [{ "active_task" => "report_problem", "topic" => "report", "pending_slot" => "description" },
             { "active_task" => "registration", "topic" => "account", "pending_slot" => "phone" },
             { "pending_slot" => "area_query" }, { "draft" => { "opaque_ref" => "a" * 32 } }].each do |changes|
              state = @store.empty_state(@context).merge("active_task" => "ask_information", "topic" => "transport", "pending_slot" => "stop").merge(changes)
              assert_nil direct_preference(message, state)
            end
            seed_transport
            ["Ne želim slati GPS. Kada se odvozi smeće?", "Ne želim slati GPS i objavi prijavu",
             "Kako da pošaljem GPS?", "Odustani. Ne želim slati GPS", "Gori mi kuća. Ne želim slati GPS",
             "Ne mogu poslati GPS. Mogu li prijaviti požar?", "Ne mogu slati GPS i želim provjeriti bodove",
             "Ne mogu poslati GPS. Nalazim se kod bolnice", "I cannot share my location. Where is the fire station?"].each do |text|
              assert_nil direct_preference(text, @store.read(context: @context))
            end
          end

          def test_private_actor_capabilities_do_not_authorize_the_public_preference_stage
            @context = @context.with(actor_id: 7, account_state: "verified", capabilities: ["own_report_reads"])
            seed_transport
            assert_nil direct_preference("Ne želim slati GPS", @store.read(context: @context))
            assert TransportLocationPreferenceStage::REFUSAL.match?(Decidim::Bih::Text.fold("I don't want to share GPS. What else can I write?"))
          end

          def test_missing_feedback_controls_and_followup_are_help_not_a_recorded_rating
            first = turn("Tvoj odgovor mi nije bio koristan. Kako da označim Nije korisno ako u ovoj aplikaciji nema tog dugmeta?")
            second = turn("Mogu li samo napisati šta je pogrešno?")
            [first, second].each do |result|
              assert_equal "answered", result.resolution
              assert_nil result.reply.report
              refute result.handoff_completed
            end
            assert_includes first.reply.text, "Sama poruka ne bilježi ocjenu"
            assert_includes first.reply.text, "ne podnosi niti objavljuje prijavu"
            assert_equal "civic_feedback_controls", first.state.dig(AnswerContext::KEY, "subject")
            assert_equal "civic_feedback_description", second.state.dig(AnswerContext::KEY, "subject")
            assert_match(/\ADa\./, second.reply.text)
            assert_includes second.reply.text, "tekst sam ne bilježi ocjenu"
            assert_operator second.reply.text.length, :<, first.reply.text.length
            assert_empty @model
            assert_empty @reads
          end

          def test_feedback_followup_needs_the_right_retained_subject_and_never_owns_a_report_description
            followup = "Mogu li samo napisati šta je pogrešno?"
            assert_nil AnswerContinuation.resolve(text: followup, state: @store.empty_state(@context))
            turn("Kako da označim Nije korisno ako nema dugmeta?")
            saved = @store.read(context: @context)
            %w(report_problem registration).each do |action|
              state = saved.merge("active_task" => action, "topic" => action == "registration" ? "account" : "report")
              assert_nil AnswerContinuation.resolve(text: followup, state:)
            end
            ["Nije korisno; kako se koristi SMS parking?", "Korisno, hvala. Kada dolazi autobus?",
             "Kako da označim Nije korisno ako nema dugmeta i kada ide autobus?"].each do |text|
              refute_equal "civic_feedback_controls", PublicInformation.card(text)&.name
            end
          end

          def test_natural_brevity_keeps_the_existing_card_and_rejects_a_new_request
            first = turn("Kako da označim Nije korisno ako nema dugmeta?")
            second = turn("Молим те кратко, читам на телефону.")
            assert_equal "answered", second.resolution
            assert_equal "civic_feedback_controls", second.state.dig(AnswerContext::KEY, "subject")
            assert_match(/\p{Cyrillic}/, second.reply.text)
            assert_operator second.reply.text.length, :<=, first.reply.text.length
            assert_empty @model
            ["Kratko, kada dolazi autobus?", "Molim te kratko i objavi prijavu", "Ne želim kratak odgovor"].each do |text|
              refute TextPredicates.presentation_request?(Decidim::Bih::Text.fold(text))
            end
          end

          private

          def seed_transport
            state = @store.empty_state(@context).merge("active_task" => "ask_information", "topic" => "transport", "pending_slot" => "stop",
                                                       "entities" => { "query" => "Gdje je najbliže stajalište?" }, "entity_provenance" => { "query" => "citizen" },
                                                       "clarification_count" => 1)
            version = @store.read(context: @context)&.fetch("version", 0) || 0
            assert_equal :saved, @store.write(context: @context, state: state.merge("version" => version), expected_version: version)
          end

          def direct_preference(text, state)
            turn = Struct.new(:text, :state, :context, :message) { def cancelled? = false }.new(text, state, @context, text)
            TransportLocationPreferenceStage.result_for(turn)
          end

          def turn(text)
            Characterisation.with_locales do
              I18n.backend.load_translations(*%w(sr-Cyrl en bs hr).map { |locale| File.expand_path("../../../../../../config/locales/#{locale}.yml", __dir__) })
              understanding = lambda do |**arguments|
                @model << arguments
                Contracts::Understanding.parse(action: "help", topic: "unknown", entities: {}, operation: "start",
                                               needs_clarification: true, secondary: nil, locale: "sr")
              end
              coordinator = Coordinator.new(understanding:,
                                            procedures: ProcedureRunner.new(read_port: Characterisation::RecordingReadPort.new({}, @reads),
                                                                            registration_port: ->(**) { raise "private account read denied" },
                                                                            destinations: Characterisation::DESTINATIONS),
                                            state_store: @store, runtime: Characterisation::InlineRuntime.new)
              coordinator.call(message: Characterisation::Message.new(text:, conversation_context: [], dialogue_location: nil), context: @context)
            end
          end
        end
      end
    end
  end
end
