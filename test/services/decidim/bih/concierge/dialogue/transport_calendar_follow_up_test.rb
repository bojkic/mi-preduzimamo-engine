# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../support/decidim/bih/dialogue_characterisation"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class TransportCalendarFollowUpTest < Minitest::Test
          def test_calendar_confirmation_keeps_line_date_and_honest_absence_of_evidence
            ["Da li za taj datum imaš potvrđenu uslugu?", "Imaš li potvrđene polaske za taj dan?",
             "Можеш ли потврдити вожњу за тај датум?"].each do |follow_up|
              source = Contracts::ReadResult.new(status: "empty", warnings: ["no_departures_published_for_service_day"],
                coverage: { "transport_query_entities" => { "route" => "G1", "date" => "2026-09-20" } })
              with_chain("Koji G1 polasci važe u nedjelju 20.9.2026?", follow_up, source) do |result, reads|
                assert_equal reads.first[:entities]["query"], reads.last[:entities]["query"]
                assert_equal "2026-09-20", reads.last[:entities]["date"]
                assert_equal "G1", reads.last[:entities]["route"]
                assert_nil reads.last[:entities]["stop"]
                assert_nil reads.last[:entities]["area_query"]
                assert_includes Text.fold(result.reply.text), "nije potvrda da autobus"
                refute_includes Text.fold(result.reply.text), "odakle"
              end
            end
          end

          def test_holiday_date_meta_question_keeps_calendar_scope_and_explains_missing_date
            ["Treba li ti tačan datum?", "Je li potreban konkretan datum putovanja?",
             "Да ли ти треба датум?"].each do |follow_up|
              source = Contracts::ReadResult.new(status: "ambiguous", warnings: ["transport_calendar_date_required"],
                coverage: { "transport_query_entities" => { "route" => "G1" } })
              with_chain("Kako ide G1 na državni praznik?", follow_up, source) do |result, reads|
                assert_equal "Kako ide G1 na državni praznik?", reads.last[:entities]["query"]
                assert_equal "G1", reads.last[:entities]["route"]
                assert_equal "time_expression", result.state["pending_slot"]
                assert_match(/\Ada napisi tacan datum/, Text.fold(result.reply.text))
                refute_includes Text.fold(result.reply.text), "odakle"
              end
            end
          end

          def test_school_or_regular_question_keeps_unresolved_journey_endpoints
            source = Contracts::ReadResult.new(status: "ambiguous", warnings: ["transport_origin_ambiguous"],
              candidates: [{ "text" => "Bijeljina (NAS)" }, { "text" => "Bijeljina (sud)" }],
              coverage: { "transport_query_entities" => { "stop" => "centra", "area_query" => "Dvorove", "date" => "2026-09-21" } })
            with_chain("Za ponedjeljak 21.9.2026, iz centra za Dvorove nakon 10?", "Da li je to školski ili redovni polazak?", source) do |result, reads|
              assert_equal "Da li je to školski ili redovni polazak?", reads.last[:entities]["query"]
              assert_equal "centra", reads.last[:entities]["stop"]
              assert_equal "Dvorove", reads.last[:entities]["area_query"]
              assert_includes result.reply.text, "ne mogu potvrditi da li je školski ili redovni"
              assert_includes result.reply.text, "Bijeljina (NAS)"
              assert_equal "stop", result.state["pending_slot"]
            end
          end

          def test_calendar_exception_does_not_claim_journeys_new_dates_or_new_topics
            state = { "active_task" => "ask_information", "topic" => "transport", "locale" => "sr",
                      "entities" => { "query" => "G1 polasci u nedjelju 20.9.2026?", "route" => "G1", "date" => "2026-09-20" } }
            ["Imaš li potvrđene polaske za sutra?", "Od NAS do Janje", "Da li za taj datum imaš potvrđenu uslugu i prijavi problem?",
             "Treba li ti tačan datum registracije?"].each do |text|
              assert_nil TransportFollowUpQuestion.calendar_continuation_query(text, state:), text
            end
            [state.merge("draft" => {}), state.merge("topic" => "account"),
             state.merge("entities" => state["entities"].merge("stop" => "NAS", "area_query" => "Janja")),
             state.merge("entities" => { "query" => "Iz centra za Dvorove u ponedjeljak 21.9.2026" }),
             state.merge("entities" => { "query" => "Kako ide G1 do Janje u nedjelju 20.9.2026" })].each do |other|
              assert_nil TransportFollowUpQuestion.calendar_continuation_query("Da li za taj datum imaš potvrđenu uslugu?", state: other)
            end
          end

          private

          def with_chain(first, follow_up, source)
            Characterisation.with_locales do
              calls = 0
              reads = []
              model = lambda do |**|
                calls += 1
                raise "follow-up must not call the model" if calls > 1
                Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: "start",
                  entities: { "query" => first }, locale: "sr", needs_clarification: false, secondary: nil)
              end
              coordinator = Coordinator.new(understanding: model,
                procedures: ProcedureRunner.new(read_port: ->(**args) { reads << args; source },
                  registration_port: ->(**) { raise "no handoff" }, destinations: Characterisation::DESTINATIONS),
                state_store: StateStore.new(redis: Characterisation::FakeRedis.new), runtime: Characterisation::InlineRuntime.new)
              context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "a" * 64,
                capabilities: ["public_reads"], now: Characterisation::NOW)
              [first, follow_up].each do |text|
                @result = coordinator.call(message: Characterisation::Message.new(text:, conversation_context: [], dialogue_location: nil), context:)
              end
              assert_equal 2, reads.length
              assert_operator calls, :<=, 1
              yield @result, reads
            end
          end
        end
      end
    end
  end
end
