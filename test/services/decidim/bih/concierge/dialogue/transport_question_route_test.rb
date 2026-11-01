# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"
require_relative "../../../../../support/decidim/bih/dialogue_characterisation"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class TransportQuestionRouteTest < Minitest::Test
          def test_conceptual_intent_families_accept_paraphrases_and_reject_topic_switches
            families = {
              "transport_transfer_missed" => ["Ako prvi autobus dolazi u 09:10 a drugi autobus kreće u 09:05, mogu li presjesti?", "Prvi stiže u 23:55, drugi polazi u 00:05, stižem li?"],
              "transport_crossing_unknown" => ["Da li mogu presjesti ako su stajališta preko puta?", "Kako presjesti sa stajališta s druge strane ulice?"],
              "transport_distance_not_walk" => ["Je li vazdušna udaljenost ista kao pješačka?", "Objasni razliku između zračne udaljenosti i hodanja."],
              "transport_absence_not_service" => ["Ako nema potvrde, to nije isto što i nema prevoza.", "Nema podataka nije dokaz da nema autobusa."]
            }
            families.each do |key, texts|
              texts.each { |text| assert_equal key, TransportQuestionRoute.conceptual_request(text)&.fetch(:key), text }
            end
            ["Je li vazdušna udaljenost ista kao pješačka i kako obrisati nalog?", "Ne pitam za presjedanje, prijavi problem.",
             "Koja je moja lozinka?", "GPS nije dostupan, objavi prijavu"].each do |text|
              assert_nil TransportQuestionRoute.conceptual_request(text), text
            end
            ["Kako mogu stići pješice do autobuske stanice?", "Možeš li napisati pješačko uputstvo do stajališta?"].each do |text|
              assert_equal "stop_navigation", CivicQuestion.classify(text)&.dig(:entities, "category"), text
            end
          end

          def test_transfer_explanation_followups_use_prior_given_times_only_in_transport_context
            state = { "active_task" => "ask_information", "topic" => "transport", "entities" => {
              "query" => "Ako prvi stiže u 09:10 a drugi ide u 09:05, stižem li?"
            } }
            ["Objasni bez izmišljanja rezervnog polaska.",
             "Pojasni računicu, nemoj izmišljati drugi polazak.",
             "Objasni mi to bez pretpostavljanja rezervnog autobusa."].each do |text|
              assert_equal "transport_transfer_missed", TransportQuestionRoute.conceptual_request(text, state:)&.fetch(:key), text
              assert_nil TransportQuestionRoute.conceptual_request(text), text
              assert_nil TransportQuestionRoute.conceptual_request(text, state: state.merge("topic" => "water")), text
            end
            ["Ne objašnjavaj presjedanje, treba mi nalog.",
             "Objasni moj nalog bez izmišljanja drugog polaska.",
             "Objasni i pretpostavi rezervni polazak."].each do |text|
              assert_nil TransportQuestionRoute.conceptual_request(text, state:), text
            end
          end

          def test_retest2_conceptual_chains_answer_without_model_source_or_account_calls
            chains = [
              ["Ako prvi stiže u 09:10 a drugi ide u 09:05, stižem li?", "Objasni bez izmišljanja rezervnog polaska."],
              ["Mogu li presjedati ako su stajališta preko puta ulice?", "Ne znaš li prelaz, reci šta nije provjereno."]
            ]
            chains.each do |messages|
              Characterisation.with_locales do
                context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "d" * 64,
                                                        capabilities: ["public_reads"], now: Characterisation::NOW)
                runner = ProcedureRunner.new(read_port: ->(**) { raise "No source needed for this conceptual question" },
                  registration_port: ->(**) { raise "No account read" }, destinations: Characterisation::DESTINATIONS)
                coordinator = Coordinator.new(understanding: ->(**) { raise "No model call" }, procedures: runner,
                  state_store: StateStore.new(redis: Characterisation::FakeRedis.new), runtime: Characterisation::InlineRuntime.new)
                messages.each do |text|
                  result = coordinator.call(message: Characterisation::Message.new(text:, conversation_context: [], dialogue_location: nil), context:)
                  assert_equal "answered", result.resolution, text
                  refute_match(/prijav[ai].{0,30}nalog/, result.reply.text)
                  assert_nil result.reply.report
                end
              end
            end
          end

          def test_retest2_cold_navigation_and_schedule_questions_are_model_independent
            ["Hvala. Kako da dođem pješke do autobuske?", "Хвала. Како да дођем пјешке до аутобуске?",
             "Koji autobus ide za Janju 16.9.2026. poslije 08:00?", "Г1 у суботу у смјеру ка НАС?",
             "Da li udaljenost vazdušnom linijom znači dužinu hodanja?"].each do |text|
              assert_equal "transport", CivicQuestion.classify(text)&.fetch(:topic), text
            end
            read = CivicQuestion.classify("Hvala. Kako da dođem pješke do autobuske?")
            assert_equal "stop_navigation", read.fetch(:entities).fetch("category")
            refute read.fetch(:entities).key?("stop")
            ["Moja približna lokacija je gradski trg.", "ГПС није доступан у овој поруци.", "Mogu napisati ulicu i orijentir."].each do |text|
              refute_equal "transport", CivicQuestion.classify(text)&.fetch(:topic), text
            end
          end

          def test_hypothetical_connection_compares_only_valid_same_day_clock_values
            request = TransportQuestionRoute.conceptual_request("Ako prvi stiže u 09:10 a drugi ide u 09:05, stižem li?")
            assert_equal "transport_transfer_missed", request.fetch(:key)
            assert_equal "09:10", request.fetch(:values).fetch(:arrival)
            assert_equal "09:05", request.fetch(:values).fetch(:departure)
            gap = TransportQuestionRoute.conceptual_request("Ako prvi stiže u 09:10 a drugi ide u 09:27, stižem li?")
            assert_equal 17, gap.fetch(:values).fetch(:minutes)
            assert_equal "transport_transfer_gap", gap.fetch(:key)
            same_time = TransportQuestionRoute.conceptual_request("Ako prvi stiže u 09:10 a drugi ide u 09:10, stižem li?")
            assert_equal "transport_transfer_gap", same_time.fetch(:key)
            assert_equal 0, same_time.fetch(:values).fetch(:minutes)
            assert_nil TransportQuestionRoute.conceptual_request("Ako prvi stiže u 29:10 a drugi ide u 09:05, stižem li?")
          end

          def test_explicit_public_stop_and_access_questions_keep_the_complete_request
            ["Treba mi najbliže stajalište od spomenika u centru, koristim kolica. Može li se sigurno prići?",
             "A jesu li G1 autobusi sigurno prilagođeni kolicima?",
             "Гдје је најближа аутобуска станица код болнице?",
             "Gdje je najbliže autobusko stajalište?", "Where is the nearest bus stop?",
             "Are buses wheelchair accessible?"].each do |text|
              read = CivicQuestion.classify(text)
              refute_nil read, text
              assert_equal "transport", read.fetch(:topic)
              assert_equal text, read.fetch(:entities).fetch("query")
            end
          end

          def test_other_stations_negations_and_mixed_account_or_write_requests_are_not_claimed
            ["Gdje je najbliža policijska stanica?", "Gdje je najbliža benzinska stanica?",
             "Ne želim najbliže stajalište", "Gdje je najbliže stajalište i koliko imam bodova?",
             "Gdje je najbliže stajalište i objavi prijavu", "Where is the nearest bus stop and my account password?",
             "A jesu li G1 autobusi prilagođeni kolicima ili trebam prijaviti problem?"].each do |text|
              refute_equal "transport", CivicQuestion.classify(text)&.fetch(:topic), text
            end
          end

          def test_nearest_request_reaches_the_actual_coordinator_and_public_reader_without_the_model
            Characterisation.with_locales do
              context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "d" * 64,
                                                      capabilities: ["public_reads"], now: Characterisation::NOW)
              reads = []
              result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["transport_origin_required"])
              runner = ProcedureRunner.new(read_port: Characterisation::RecordingReadPort.new({ read: result }, reads),
                                           registration_port: ->(**) { raise "no account read" }, destinations: Characterisation::DESTINATIONS)
              coordinator = Coordinator.new(understanding: ->(**) { raise "no model call" }, procedures: runner,
                                            state_store: StateStore.new(redis: Characterisation::FakeRedis.new), runtime: Characterisation::InlineRuntime.new)
              text = "Gdje je najbliže autobusko stajalište?"
              reply = coordinator.call(message: Characterisation::Message.new(text:, conversation_context: [], dialogue_location: nil), context:)
              assert_equal "clarification", reply.resolution
              assert_equal "transport", reads.last.fetch(:topic)
              assert_equal text, reads.last.fetch(:entities).fetch("query")
              assert_nil reply.reply.report
              refute reply.handoff_completed
            end
          end
        end
      end
    end
  end
end
