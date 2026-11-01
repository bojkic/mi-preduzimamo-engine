# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"
require_relative "../../../../../support/decidim/bih/dialogue_characterisation"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # "A drugo pitanje?" — at the real coordinator boundary.
        #
        # == The defect
        #
        # `r5c09`, verbatim: the citizen asked THREE questions in one message
        # ("Kad se odvozi smeće u Ulici Meše Selimovića i kako da se
        # registrujem i ko vodi u trci komšiluka?"), was answered the third,
        # and then asked for the others by ordinal. "A drugo pitanje?" returned
        # the account menu and "A treće?" the rewards catalogue. Re-measured
        # live on 14.09.2026: "Koliko bodova nosi prijava problema? A kada je
        # lansiranje?" answers the first and returns the top-level four-option
        # menu to "A drugo pitanje?".
        #
        # == Why the queue is the citizen's message and not the last answer
        #
        # Remembering the last ANSWERED subject cannot recover an UNANSWERED
        # one, and in `r5c09` continuing from it answered the wrong one of the
        # three. The queue here is their own message, split into the questions
        # they actually asked, in the order they asked them — so "drugo
        # pitanje" means the second one THEY asked, which is the only thing it
        # has ever meant.
        class QuestionQueueTest < Minitest::Test
          NOW = Characterisation::NOW
          RAISING_SPY = ->(**) { raise "a queued question is served from the citizen's own words, never the model" }
          # What the model came back with for the opening multi-question turn.
          # Anything that reads it instead of the queue shows up as this topic.
          WASTE = lambda do |**|
            Contracts::Understanding.parse(action: "ask_information", topic: "waste",
                                           entities: { "query" => "odvoz smeca" }, operation: "start",
                                           needs_clarification: false, secondary: nil, locale: "sr")
          end

          def setup
            @redis = Characterisation::FakeRedis.new
            @store = StateStore.new(redis: @redis)
            @reads = []
            @model = []
            @read_result = Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 9), facts: [])
          end

          def test_complementary_transfer_facets_do_not_create_an_unanswered_question_queue
            ["Gdje tačno presjedam i koliko čekam drugi autobus?",
             "Gdje ulazim i koliko traje čekanje pri presjedanju?",
             "Гдје тачно пресједам и колико чекам други аутобус?"].each do |text|
              conversation do
                say("Koji autobus ide od Intergaja do ATC-a?")
                answer = say(text)
                assert_nil @store.read(context:)[StateStore::QUESTION_QUEUE_KEY], text
                refute_match(/(?:Sačuvala|Сачувала).*(?:pitanje|питање)/, answer.reply.text, text)
              end
            end
          end

          def test_transport_facet_does_not_swallow_a_genuine_other_question
            conversation do
              say("Koji autobus ide od Intergaja do ATC-a?")
              say("Gdje presjedam i kada je lansiranje?", understanding: WASTE)
              assert_equal ["Gdje presjedam", "kada je lansiranje"],
                @store.read(context:).fetch(StateStore::QUESTION_QUEUE_KEY).fetch("questions")
              say("A drugo pitanje?")
              assert_equal "goodwill", @reads.last.fetch(:topic)
              assert_equal "invitation", @reads.last.fetch(:entities)["category"]
            end
          end

          def test_independent_transport_calendar_question_remains_queued
            conversation do
              say("Koji autobus ide od Intergaja do ATC-a?")
              say("Gdje presjedam i kako razlikuješ školske i redovne polaske?", understanding: WASTE)
              assert_equal ["Gdje presjedam", "kako razlikuješ školske i redovne polaske"],
                @store.read(context:).fetch(StateStore::QUESTION_QUEUE_KEY).fetch("questions")
            end
          end

          # --- the defect ----------------------------------------------------

          # Three questions, one message. The second and the third are still
          # the citizen's to ask for, and each lands on its OWN subject.
          def test_the_second_and_third_questions_of_one_message_are_each_answerable
            conversation do
              say("Kako da zaradim bodove i ko trenutno vodi i kada je lansiranje?", understanding: WASTE)

              assert_equal ["Kako da zaradim bodove", "ko trenutno vodi", "kada je lansiranje"],
                           @store.read(context:).fetch(StateStore::QUESTION_QUEUE_KEY).fetch("questions"),
                           "the citizen's own three questions, in their own order and their own words"

              say("A drugo pitanje?")

              assert_equal "launch", @reads.last.fetch(:topic), "the SECOND question, not the one just answered"
              assert_equal "race_standings", @reads.last.fetch(:entities)["category"]

              say("A treće?")

              assert_equal "goodwill", @reads.last.fetch(:topic), "the THIRD question"
              assert_equal "invitation", @reads.last.fetch(:entities)["category"]
              assert_empty @model, "a queued question is served from the citizen's own words, never the model"
            end
          end

          # The shape measured live: two questions, one question mark each.
          def test_a_second_question_written_after_a_question_mark_is_queued
            conversation do
              say("Kako da zaradim bodove? A kada je lansiranje?", understanding: WASTE)
              say("A drugo pitanje?")

              assert_equal "goodwill", @reads.last.fetch(:topic)
              assert_equal "invitation", @reads.last.fetch(:entities)["category"]
            end
          end

          # The queue outlives the turn that opened it, which is what makes
          # "A treće?" work after "A drugo pitanje?" — asked in either order.
          def test_the_ordinal_indexes_the_citizens_list_and_not_a_cursor
            conversation do
              say("Kako da zaradim bodove i ko trenutno vodi i kada je lansiranje?", understanding: WASTE)
              say("A treće?")

              assert_equal "invitation", @reads.last.fetch(:entities)["category"]

              say("A drugo pitanje?")

              assert_equal "race_standings", @reads.last.fetch(:entities)["category"], "asking out of order still works"
            end
          end

          # --- what must NOT change -------------------------------------------

          # No queue: the turn is exactly what it is today. This is the case
          # the previous owner's decline protected, and it still declines.
          def test_a_queued_question_with_nothing_queued_still_reaches_the_model
            conversation do
              say("Kako da zaradim bodove?")
              answer = say("A drugo pitanje?", understanding: WASTE)

              assert_equal "waste", @reads.last.fetch(:topic)
              assert_equal 1, @model.length, "with no queue, the turn is still the provider's"
              refute_nil answer.reply.text
            end
          end

          # An ordinal past the end of the citizen's own list recovers nothing.
          # Serving a DIFFERENT question would be the `r5c09` defect again.
          def test_an_ordinal_past_the_end_of_the_list_declines_rather_than_guessing
            conversation do
              say("Kako da zaradim bodove i kada je lansiranje?", understanding: WASTE)
              before = @model.length
              say("A peto?", understanding: WASTE)

              assert_equal before + 1, @model.length, "the turn falls through instead of serving another question"
              assert_equal "waste", @reads.last.fetch(:topic)
            end
          end

          # "ostalo" names no position and nothing here knows which of the list
          # has been served, so it keeps declining — a recorded boundary.
          def test_ostalo_names_no_position_and_still_declines
            conversation do
              say("Kako da zaradim bodove i kada je lansiranje?", understanding: WASTE)
              before = @model.length
              say("a ostalo", understanding: WASTE)

              assert_equal before + 1, @model.length
            end
          end

          # A conjunction joining two NOUNS is not two questions. Splitting on
          # a bare "i" would invent one out of every list a citizen writes.
          def test_a_conjunction_between_nouns_is_never_split_into_questions
            assert_nil QuestionQueue.split("Treba mi odvoz smeća i kabastog otpada u mojoj ulici")
            assert_nil QuestionQueue.split("Kako da prijavim rupu i slomljenu klupu?")
            assert_nil QuestionQueue.split("Kako da prijavim problem?")
          end

          # The queue holds the citizen's own words, bounded, and never
          # anything credential-shaped.
          def test_the_queue_is_bounded_and_refuses_credential_bearing_text
            assert_nil QuestionQueue.split("a" * 500)
            assert_nil QuestionQueue.split("Kako da zaradim bodove i kada je lansiranje i sta je trka komsiluka " \
                                           "i ko trenutno vodi u trci i gdje je moja pozivnica?"),
                       "more than four is a paragraph, not a list of questions"
            queue = QuestionQueue.capture("Kako da zaradim bodove i kada je lansiranje?",
                                          now: NOW, state_expires_at: NOW.to_f + Contracts::CONTEXT_TTL)

            assert_equal ["Kako da zaradim bodove", "kada je lansiranje"], queue.fetch("questions")
          end

          # Every rule in the normalizer is a DROP, never a raise: a
          # convenience must not be able to destroy the conversation state.
          def test_a_malformed_or_expired_queue_is_dropped_rather_than_raised
            expires = NOW.to_f + Contracts::CONTEXT_TTL
            [nil, "text", {}, { "questions" => ["one only"], "opened_at" => NOW.to_f, "expires_at" => expires },
             { "questions" => %w(a b), "opened_at" => NOW.to_f, "expires_at" => expires },
             { "questions" => ["Kako da zaradim bodove", "kada je lansiranje"], "opened_at" => NOW.to_f, "expires_at" => NOW.to_f - 1 },
             { "questions" => ["Kako da zaradim bodove", "kada je lansiranje"], "opened_at" => NOW.to_f }].each do |value|
              assert_nil QuestionQueue.normalize(value, now: NOW, state_expires_at: expires), value.inspect
            end
          end

          # A cancellation rebuilds the state from empty_state, so the queue
          # goes with everything else.
          def test_a_cancellation_clears_the_queue
            conversation do
              say("Kako da zaradim bodove i kada je lansiranje?", understanding: WASTE)
              say("odustani")
              say("A drugo pitanje?", understanding: WASTE)

              assert_equal "waste", @reads.last.fetch(:topic), "a cancelled conversation keeps no queue"
            end
          end

          private

          def context(now: NOW)
            Contracts::TrustedContext.new(
              organization_id: Characterisation::ORGANIZATION_ID, conversation_key: Characterisation::CONVERSATION_KEY,
              actor_id: Characterisation::ACTOR_ID, account_state: "verified",
              capabilities: Characterisation::CAPABILITIES, now:
            )
          end

          def conversation(&)
            @redis = Characterisation::FakeRedis.new
            @store = StateStore.new(redis: @redis)
            @reads = []
            @model = []
            Characterisation.with_locales(&)
          end

          def say(text, understanding: RAISING_SPY, now: NOW)
            spy = lambda do |**arguments|
              @model << arguments
              understanding.call(**arguments)
            end
            coordinator = Coordinator.new(
              understanding: spy,
              procedures: ProcedureRunner.new(
                read_port: lambda { |**arguments|
                  @reads << arguments
                  @read_result
                },
                registration_port: ->(**) { Characterisation::DEFAULT_HANDOFF },
                destinations: Characterisation::DESTINATIONS
              ),
              state_store: @store, runtime: Characterisation::InlineRuntime.new
            )
            coordinator.call(message: Characterisation::Message.new(text:, conversation_context: [], dialogue_location: nil),
                             context: context(now:))
          end
        end
      end
    end
  end
end
