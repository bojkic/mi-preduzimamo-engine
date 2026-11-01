# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../support/decidim/bih/dialogue_characterisation"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class TransportFollowUpQuestionTest < Minitest::Test
          def test_time_window_reminders_are_scoped_and_do_not_replace_corrections
            state = { "active_task" => "ask_information", "topic" => "transport", "entities" => { "time_expression" => "23:40" } }
            ["Nemoj navesti jutarnji autobus kao da tek slijedi danas.",
             "Ne prikazuj jutarnji polazak kao naredni večeras.",
             "Nemoj ponuditi raniji autobus kao kasniji.",
             "Немој навести јутарњи аутобус као да тек слиједи данас."].each do |text|
              assert_equal "transport_window", TextPredicates.read_follow_up_kind(text, state), text
              assert_nil TextPredicates.read_follow_up_kind(text, state.merge("topic" => "water")), text
              assert_nil TextPredicates.read_follow_up_kind(text, state.merge("draft" => {})), text
              assert_nil TextPredicates.read_follow_up_kind(text, state.merge("entities" => {})), text
            end
            ["Nemoj navesti jutarnji autobus, treba mi poslije 13:00.",
             "Ne prikazuj raniji autobus kao sljedeći, sutra putujem.",
             "Nemoj navesti jutarnji autobus nego večernji.",
             "Nemoj ponuditi raniji autobus kao kasniji i prijavi problem."].each do |text|
              assert_nil TextPredicates.read_follow_up_kind(text, state), text
            end
          end

          def test_late_day_reminder_keeps_query_date_and_clock_and_asks_the_missing_origin
            Characterisation.with_locales do
              context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "d" * 64,
                capabilities: ["public_reads"], now: Characterisation::NOW)
              store = StateStore.new(redis: Characterisation::FakeRedis.new)
              model_calls = []
              query = "Danas u 23:40 mogu li još do Janje?"
              model = lambda do |**|
                model_calls << true
                Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: "start",
                  entities: { query:, area_query: "Janja", date: "2026-09-15", time_expression: "23:40" },
                  locale: "sr", needs_clarification: false, secondary: nil)
              end
              reads = []
              port = Characterisation::RecordingReadPort.new({ read: Contracts::ReadResult.new(status: "ambiguous",
                warnings: ["transport_origin_required"], coverage: { transport_query_entities: {
                  "area_query" => "Janja", "date" => "2026-09-15", "time_expression" => "23:40"
                } }) }, reads)
              runner = ProcedureRunner.new(read_port: port, registration_port: ->(**) { raise "No account" }, destinations: Characterisation::DESTINATIONS)
              coordinator = Coordinator.new(understanding: model, procedures: runner, state_store: store, runtime: Characterisation::InlineRuntime.new)
              [query, "Nemoj navesti jutarnji autobus kao da tek slijedi danas."].each do |text|
                result = coordinator.call(message: Characterisation::Message.new(text:, conversation_context: [], dialogue_location: nil), context:)
                assert_equal "clarification", result.resolution
                assert_match(/(?:Odakle|polazno stajalište)/, result.reply.text)
                refute_match(/Šta treba da ispravim/, result.reply.text)
              end
              assert_equal 1, model_calls.length
              assert_equal query, reads.last.fetch(:entities).fetch("query")
              assert_equal "23:40", reads.last.fetch(:entities).fetch("time_expression")
              assert_equal "2026-09-15", reads.last.fetch(:entities).fetch("date")
              assert_equal "Janja", reads.last.fetch(:entities).fetch("area_query")
              assert_nil store.read(context:)["entities"]["stop"]
            end
          end

          def test_nearest_stop_landmark_answers_keep_the_nearest_question_without_a_destination
            [["Nalazim se kod gradske biblioteke u Bijeljini.", "gradske biblioteke"],
             ["Тренутно сам поред библиотеке у Бијељини.", "библиотеке"],
             ["Kod gradskog parka.", "gradskog parka"]].each do |text, place|
              Characterisation.with_locales do
                context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "e" * 64,
                  capabilities: ["public_reads"], now: Characterisation::NOW)
                store = StateStore.new(redis: Characterisation::FakeRedis.new)
                reads = []
                port = lambda do |**args|
                  reads << args
                  if reads.length == 1
                    Contracts::ReadResult.new(status: "ambiguous", warnings: ["transport_origin_required"])
                  else
                    # An unmatched public landmark must ask for origin detail,
                    # without manufacturing a stop or demanding a destination.
                    Contracts::ReadResult.new(status: "empty", warnings: ["reviewed_origin_stop_required"],
                      coverage: { "transport_query_entities" => { "stop" => place } })
                  end
                end
                coordinator = Coordinator.new(understanding: ->(**) { raise "nearest clarification must not call model" },
                  procedures: ProcedureRunner.new(read_port: port, registration_port: ->(**) { raise "no handoff" },
                    destinations: Characterisation::DESTINATIONS), state_store: store, runtime: Characterisation::InlineRuntime.new)
                message = ->(value) { Characterisation::Message.new(text: value, conversation_context: [], dialogue_location: nil) }
                first = coordinator.call(message: message.call("Gdje je najbliže stajalište?"), context:)
                assert_equal "stop", first.state["pending_slot"]
                result = coordinator.call(message: message.call(text), context:)
                assert_equal 2, reads.length
                assert_equal "Najbliže stajalište. #{text}", reads.last[:entities]["query"]
                assert_nil reads.last[:entities]["area_query"]
                assert_equal "stop", result.state["pending_slot"]
                assert_includes Text.fold(result.reply.text), Text.fold(place)
                refute_includes Text.fold(result.reply.text), "do kojeg"
                assert_equal(text.match?(/\p{Cyrillic}/) ? "sr-Cyrl" : "sr", reads.last[:locale])
              end
            end
          end

          def test_nearest_continuation_does_not_claim_changed_destination_topic_or_ordinary_journey
            state = { "active_task" => "ask_information", "topic" => "transport", "pending_slot" => "stop",
                      "entities" => { "query" => "Gdje je najbliže stajalište?" }, "locale" => "sr" }
            ["Kod biblioteke do Janje", "Kod biblioteke i prijavi rupu", "Nalazim se kod biblioteke. Kada radi?",
             "Ne tražim stajalište, nego račun", "Kod biblioteke, pošalji poruku", "Od NAS do Janje"].each do |text|
              assert_nil TransportFollowUpQuestion.nearest_location_query(text, state:), text
            end
            [state.merge("draft" => {}), state.merge("topic" => "account"),
             state.merge("entities" => { "query" => "Autobus do Janje" }),
             state.merge("entities" => state["entities"].merge("area_query" => "Janja")),
             state.merge("pending_slot" => nil)].each do |other|
              assert_nil TransportFollowUpQuestion.nearest_location_query("Kod biblioteke", state: other)
            end
          end

          def test_retest2_facet_families_accept_paraphrases_without_claiming_new_tasks
            ["Koliko čekam presjedanje?", "Koliko vremena imam za prelazak?", "Gdje se ukrcavam?", "A odakle tačno ulazim?",
             "Uporedi drugi smjer ka NAS", "Da li je drugi smjer isti?", "Objasni gradski i međugradski red",
             "Koje su razlike gradskog i međugradskog prevoza?", "Je li polazak školski ili redovni?",
             "Koji su školski polasci?", "Zadrži krajnje odredište", "Nemoj mijenjati odredište u centar"].each do |text|
              assert TransportFollowUpQuestion.facet_follow_up?(text), text
            end
            ["Koliko bodova dobijem za presjedanje?", "Gdje da prijavim opasno stajalište?", "Ne pitam za drugi smjer, kako obrisati nalog?"].each do |text|
              refute TransportFollowUpQuestion.facet_follow_up?(text), text
            end
          end

          def test_destination_refinement_uses_retained_subject_but_does_not_claim_origin_refinement
            state = { "active_task" => "ask_information", "topic" => "transport", "locale" => "sr", "entities" => { "area_query" => "škole" } }
            ["Mislim na školu u Janji.", "Мислим на школу у Јањи.", "Do škole u Janji"].each do |text|
              assert TransportFollowUpQuestion.destination_refinement?(text, state:), text
              assert_equal "continue", TransportFollowUpQuestion.call(text, state:).fetch(:operation)
            end
            refute TransportFollowUpQuestion.destination_refinement?("Mislim na autobusku stanicu", state:)
            refute TransportFollowUpQuestion.destination_refinement?("Iz škole u Janji", state:)
            refute TransportFollowUpQuestion.destination_refinement?("Do škole pa do bolnice", state:)
            refute TransportFollowUpQuestion.destination_refinement?("Mislim na školu u Janji i prijavi rupu", state:)
            refute TransportFollowUpQuestion.destination_refinement?("Mislim na školu u Janji. Kako obrisati nalog?", state:)
          end

          def test_read_constraints_are_deterministic_only_inside_a_public_read
            state = { "active_task" => "ask_information", "topic" => "transport", "locale" => "sr" }
            ["Не желим да направим пријаву.", "Nemoj izmisliti noćnu autobusku liniju.",
             "Немој обећати везу ако нема потврђеног другог поласка."].each do |text|
              refute_nil TextPredicates.read_follow_up_kind(text, state)
              assert_nil TextPredicates.read_follow_up_kind(text, state.merge("draft" => {}))
              assert_nil TextPredicates.read_follow_up_kind(text, state.merge("active_task" => "report_problem"))
            end
            assert_nil TextPredicates.read_follow_up_kind("Nemoj izmisliti noćnu autobusku liniju. Prijavi problem", state)
          end

          def test_supplied_clock_corrections_and_inflected_origins_reach_the_reader
            state = { "active_task" => "ask_information", "topic" => "transport", "locale" => "sr" }
            ["Ne u 9, treba mi prvi nakon 13 časova.", "Не у 9, треба ми први након 13 часова.",
             "Sa nove autobuske stanice.", "Pitao sam za subotu, ne za danas."].each do |text|
              result = TransportFollowUpQuestion.call(text, state:)
              refute_nil result, text
              assert_equal text, result.fetch(:entities).fetch("query")
              assert_equal "continue", result.fetch(:operation)
            end
            assert_nil TransportFollowUpQuestion.call("Ne u 9, kako da obrišem nalog?", state:)
          end

          def test_missing_origin_and_day_followups_reach_reader_without_reclassifying_the_task
            Characterisation.with_locales do
              context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "d" * 64,
                                                      capabilities: ["public_reads"], now: Characterisation::NOW)
              store = StateStore.new(redis: Characterisation::FakeRedis.new)
              calls = []
              model = lambda do |**|
                calls << :model
                Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: "start",
                                               entities: { area_query: "Intergaj", date: "2026-09-19" },
                                               locale: "sr", needs_clarification: false, secondary: nil)
              end
              reads = []
              port = Characterisation::RecordingReadPort.new({ read: Contracts::ReadResult.new(status: "ambiguous",
                                                                                               warnings: ["transport_origin_required"]) }, reads)
              runner = ProcedureRunner.new(read_port: port, registration_port: ->(**) { raise "no handoff" },
                                           destinations: Characterisation::DESTINATIONS)
              coordinator = Coordinator.new(understanding: model, procedures: runner, state_store: store,
                                            runtime: Characterisation::InlineRuntime.new)
              ["Autobus do Intergaja 2026-09-19", "Od NAS", "A nedjelju?", "Од нове станице"].each do |text|
                coordinator.call(message: Characterisation::Message.new(text:, conversation_context: [], dialogue_location: nil), context:)
              end
              assert_equal [:model], calls
              assert_equal 4, reads.length
              assert_equal "Od NAS", reads[1].fetch(:entities)["query"]
              assert_equal "Intergaj", reads[1].fetch(:entities)["area_query"]
              assert_equal "2026-09-19", reads[1].fetch(:entities)["date"]
              assert_equal "A nedjelju?", reads[2].fetch(:entities)["query"]
              assert_equal "sr-Cyrl", reads[3].fetch(:locale)
            end
          end

          def test_clock_minutes_are_recognized_and_other_topic_questions_are_not_claimed
            state = { "active_task" => "ask_information", "topic" => "transport", "locale" => "sr" }
            ["U 09:30", "A u subotu nakon 09:30?"].each do |text|
              assert_equal text, TransportFollowUpQuestion.call(text, state:).fetch(:entities).fetch("query")
            end
            ["Do kada radi biblioteka?", "Od kada počinje manifestacija?", "From now on answer in English",
             "Za otpad me zanima odvoz", "Od komšije želim prijaviti problem",
             "Do koje godine traje program?", "Od mene se traži uplata, zašto?",
             "To je sve", "To je to", "To ne znam"].each do |text|
              assert_nil TransportFollowUpQuestion.call(text, state:), text
            end
          end

          def test_live_and_accessibility_questions_keep_transport_without_changing_permissions
            state = { "active_task" => "ask_information", "topic" => "transport", "locale" => "sr" }
            ["Možeš li uživo vidjeti kasni li taj autobus?", "А јесу ли Г1 аутобуси сигурно прилагођени колицима?",
             "Is this bus wheelchair accessible?"].each do |text|
              answer = TransportFollowUpQuestion.call(text, state:)
              assert_equal "continue", answer.fetch(:operation)
              assert_equal({ "query" => text }, answer.fetch(:entities))
              assert_nil TransportFollowUpQuestion.call(text, state: state.merge("topic" => "account"))
            end
            ["Ne pitam kasni li autobus, nego gdje je ambulanta", "Ne zanima me da li autobus kasni. Gdje je biblioteka?",
             "Možeš li vidjeti kasni li autobus? Gdje je biblioteka?"].each do |text|
              assert_nil TransportFollowUpQuestion.call(text, state:), text
            end
          end

          def test_no_transport_context_or_an_active_draft_cannot_be_claimed
            state = { "active_task" => "ask_information", "topic" => "waste", "locale" => "sr" }
            assert_nil TransportFollowUpQuestion.call("Od NAS", state:)
            assert_nil TransportFollowUpQuestion.call("Od NAS", state: state.merge("topic" => "transport", "draft" => {}))
            assert_nil TransportFollowUpQuestion.call("Kako da se registrujem?", state: state.merge("topic" => "transport"))
          end
        end
      end
    end
  end
end
