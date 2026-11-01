# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"
require_relative "../../../../../support/decidim/bih/dialogue_characterisation"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # The three conversation-state defects the 648-turn round-3 replay
        # found (docs/audits/2026-09-14-milica-round3-retest/), at the real
        # coordinator boundary, replayed from the frozen corpus.
        #
        #   * item 10 — a turn that names its own subject or its own location
        #     inherited the previous subject's street, and was answered with
        #     the wrong parking zone's phone number and price;
        #   * item 6 — a decorated cancel ("ne, odustajem") did not cancel and
        #     the draft stayed live;
        #   * item 9 — "nastavi" had lost the citizen's own saved question, and
        #     the offer that teaches the word was no longer made.
        #
        # The model is a spy that RAISES wherever the turn must be answered
        # without it, so a fix that quietly starts calling the provider fails
        # here rather than passing slower.
        class ConversationStatePrecedenceTest < Minitest::Test
          NOW = Characterisation::NOW
          RAISING_SPY = ->(**) { raise "the model must not be called for this turn" }
          # Spelled out rather than read from the module, so this file still
          # LOADS against a tree without the cursor and reports a failure per
          # test instead of one collection error for all of them.
          CURSOR_TEST = "served"
          # Likewise spelled out: the item-10 test must fail on the inherited
          # street, not on a missing constant.
          LOCATION_SLOTS = %w(area_query area_slug street address stop).freeze
          READ_FACT = {
            "id" => "fact:1", "kind" => "notice", "text" => "Odgovor iz izvora.", "source_id" => "src",
            "source_label" => "Izvor", "source_url" => "https://example.org/x", "checked_at" => "2026-09-14T09:00:00Z"
          }.freeze
          # r5c09, verbatim: three questions in one message.
          THREE_QUESTIONS = "Kad se odvozi smeće u Ulici Meše Selimovića i kako da se registrujem i ko vodi u trci komšiluka?"

          def setup
            @redis = Characterisation::FakeRedis.new
            @store = StateStore.new(redis: @redis)
            @reads = []
            @model = []
            @read_result = Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 9), facts: [READ_FACT])
          end

          # --- item 10: an explicit subject inherits no retained location -----

          # b1c01 T4, the worst factual error of the replay. The citizen asked
          # about waste in Ulica Filipa Višnjića and, three turns later, for
          # "broj za SMS parking u plavoj zoni". The street survived the switch
          # (the model re-emits retained slot values, and the switch had
          # already reset the bag the echo fence compares against), and the
          # host's reviewed street/segment rows answered with the WHITE zone —
          # 083 5500 at 1,50 KM/h instead of the blue zone's 083 5502 at
          # 0,60 KM/h. The number and the price are both things a citizen acts
          # on. The end-to-end proof of the two numbers is the host's
          # test/contracts/milica_directory_answer_test.rb; what is proved here
          # is that the reader is never handed the stale street to answer from.
          def test_an_explicit_zone_inherits_no_street_from_the_previous_subject
            conversation do
              say("Kad se kupi smeće u Ulici Filipa Višnjića?", understanding: waste_with_street)

              assert_equal "Filipa Višnjića", read.fetch(:entities).fetch("street")

              say("A sada mi reci broj za SMS parking u plavoj zoni.", understanding: parking_echoing_the_street)

              assert_equal "parking", read.fetch(:topic)
              assert_includes read.fetch(:entities).fetch("query"), "plavoj zoni"
              LOCATION_SLOTS.each do |slot|
                assert_nil read.fetch(:entities)[slot], "#{slot} was inherited into a turn that named its own zone"
              end
              assert_nil @store.read(context:).fetch("entities")["street"], "and it is not left in the bag for the next turn either"
            end
          end

          # The other half of the same rule: a location the citizen DID name
          # this turn is theirs, and survives the switch. Serbian declines a
          # street name, so "u Nušićevoj" says "Nušićeva" — matching on the
          # literal form alone would have dropped it.
          def test_a_location_the_citizen_names_this_turn_survives_the_switch
            ["Kako se plaća parking u Nušićevoj?", "Kako se plaća parking u Nušićeva?"].each do |text|
              conversation do
                say("Kad se kupi smeće u Ulici Filipa Višnjića?", understanding: waste_with_street)
                say(text, understanding: parking_with_street("Nušićeva"))

                assert_equal "Nušićeva", read.fetch(:entities)["street"], text
              end
            end
          end

          # The unchanged case, kept as a regression guard: the SAME subject
          # keeps the street the citizen gave it, which is what lets "a
          # kabasti?" be answered where they live.
          def test_the_same_subject_keeps_the_street_the_citizen_gave_it
            conversation do
              say("Kad se kupi smeće u Ulici Filipa Višnjića?", understanding: waste_with_street)
              say("A kabasti otpad?", understanding: waste_follow_up)

              assert_equal "Filipa Višnjića", read.fetch(:entities).fetch("street")
            end
          end

          # A category is not a place. The deterministic routes legitimately
          # re-supply one across a switch, so the rule is scoped to locations.
          def test_the_rule_is_scoped_to_locations_and_leaves_other_slots_alone
            assert_equal LOCATION_SLOTS, ProcedureRunner::CARRIED_LOCATION_KEYS
            conversation do
              say("Koliko bodova nosi volonterski sat?")
              say("A koliko za registraciju?")

              assert_equal "earn", read.fetch(:entities).fetch("category")
            end
          end

          # --- item 6: cancel outranks correction parsing ---------------------

          # b?c: "ne, odustajem" re-prompted and the draft stayed live, proved
          # by a bare "odustani" a turn later still finding a task to cancel.
          def test_a_decorated_cancel_cancels_and_takes_the_draft_with_it
            ["ne, odustajem", "ne, prekidam", "ne hvala, odustani", "u redu, odustajem",
             "не, одустајем", "не хвала, одустани"].each do |text|
              conversation(state: pending_report) do
                answer = say(text)

                assert_equal "cancelled", answer.resolution, text
                after = @store.read(context:)

                assert_nil after.fetch("draft"), "the draft survived #{text.inspect}"
                assert_nil after.fetch("active_task"), "the task survived #{text.inspect}"
                assert_empty @model, "a cancel never reaches the model"
              end
            end
          end

          def test_every_decorated_cancel_is_recognised_as_cancellation_wording
            ["ne, odustajem", "ne, prekidam", "ne hvala, odustani", "u redu, odustajem", "dobro, odustani",
             "ok, odustani", "не, одустајем", "не хвала, одустани", "Ne, odustajem od prijave"].each do |text|
              assert ProcedureRunner.cancellation_wording?(text), text
            end
          end

          # A correction is not a cancel, and neither is a refusal. The strip
          # leaves a request behind, and a request is not a cancel command.
          def test_a_genuine_correction_or_refusal_is_never_read_as_a_cancel
            ["Ne pitam za parking. Pitam koliko košta karta.", "Nisam to pitala.", "Ne, hvala.",
             "ne, nemoj to", "Ne, pitam šta je MI PRE(D)UZIMAMO? Prvi put sam ovdje.",
             "Treba mi službena stranica toplane, ne prijava problema."].each do |text|
              refute ProcedureRunner.cancellation_wording?(text), text
            end
          end

          # The correction path still owns the message it always owned: the
          # draft is untouched and the turn is not a cancellation.
          def test_a_correction_still_repairs_instead_of_cancelling
            draft = { "reference" => "draft-reference-0009", "revision" => 1, "expires_at" => NOW.to_f + 600 }
            conversation(state: pending_report.merge("draft" => draft)) do
              answer = say("Ne pitam za parking. Pitam koliko košta karta.",
                           understanding: ->(**) { Contracts::Understanding.clarify(locale: "sr") })

              refute_equal "cancelled", answer.resolution
              after = @store.read(context:)

              assert_equal draft, after.fetch("draft")
              assert_equal "report_problem", after.fetch("active_task")
            end
          end

          # --- item 9: the queue and the stash, both live ---------------------

          # r5c09. Three questions, one message; the reviewed race card answers
          # the third and writes no task, so nothing is suspended and "nastavi"
          # answered "Nemam sačuvano pitanje" to a citizen with two questions
          # outstanding. The queue answers them, in the order they asked them.
          def test_the_resume_word_answers_the_citizens_own_unanswered_questions
            conversation do
              say(THREE_QUESTIONS)
              nothing = I18n.t("decidim.bih.dialogue.resume_nothing", locale: :sr)

              first = say("nastavi", understanding: ->(**) { Contracts::Understanding.clarify(locale: "sr") })

              refute_equal nothing, first.reply.text
              assert_equal "Kad se odvozi smeće u Ulici Meše Selimovića", @model.last.fetch(:message).text

              say("nastavi", understanding: ->(**) { Contracts::Understanding.clarify(locale: "sr") })

              assert_equal "kako da se registrujem", @model.last.fetch(:message).text
              # The third was the one already answered; once the list is
              # exhausted the turn is exactly what it was before.
              say("nastavi")

              assert_equal nothing, say("nastavi").reply.text
            end
          end

          # The offer that teaches the word, on the turn that creates something
          # to resume. It went missing because a card suspends nothing.
          def test_a_message_carrying_several_questions_teaches_the_resume_word
            conversation do
              answer = say(THREE_QUESTIONS)

              assert_equal "answered", answer.resolution
              assert_includes answer.reply.text, I18n.t("decidim.bih.dialogue.resume_offer", locale: :sr)
              assert_includes answer.reply.text, "nastavi"
            end
          end

          def test_a_single_question_message_is_not_decorated_with_the_offer
            conversation do
              answer = say("Šta je trka komšiluka?")

              refute_includes answer.reply.text, I18n.t("decidim.bih.dialogue.resume_offer", locale: :sr)
            end
          end

          # The stash holds work with slots in it; the queue holds words. So
          # the stash is resumed first and the queue is not consumed for it.
          def test_the_suspended_task_outranks_the_queue
            suspended = @store.empty_state(context).slice(*StateStore::TASK_KEYS).merge(
              "active_task" => "ask_information", "topic" => "transport", "pending_slot" => nil,
              "entities" => { "query" => "Koliko košta autobuska karta?" }, "entity_provenance" => { "query" => "citizen" }
            )
            conversation do
              say(THREE_QUESTIONS)
              seed_suspended(suspended)
              say("nastavi", understanding: ->(**) { Contracts::Understanding.clarify(locale: "sr") })
              after = @store.read(context:)

              assert_equal "transport", after.fetch("topic"), "the stash is what a resume takes first"
              assert_nil after.fetch("suspended_task")
              assert_equal 0, QuestionQueue.served(after.fetch(StateStore::QUESTION_QUEUE_KEY)),
                           "resuming the stash must not consume the queue"
            end
          end

          # An ordinal names a position in the citizen's own list. Navigating it
          # is not consuming it.
          def test_an_ordinal_request_does_not_move_the_cursor
            conversation do
              say(THREE_QUESTIONS)
              say("A drugo pitanje?", understanding: ->(**) { Contracts::Understanding.clarify(locale: "sr") })

              assert_equal 0, QuestionQueue.served(@store.read(context:).fetch(StateStore::QUESTION_QUEUE_KEY))
            end
          end

          # The cursor is optional: a queue written before it existed keeps
          # working and simply starts at zero.
          def test_the_cursor_is_optional_bounded_and_never_raises
            window = { "opened_at" => NOW.to_f, "expires_at" => NOW.to_f + 60 }
            questions = ["Kad se odvozi smeće u Ulici Meše Selimovića", "kako da se registrujem"]
            legacy = { "questions" => questions }.merge(window)

            assert_equal CURSOR_TEST, QuestionQueue::CURSOR
            assert_equal 0, QuestionQueue.served(QuestionQueue.normalize(legacy, now: NOW, state_expires_at: NOW.to_f + 1800))
            assert_equal questions.first, QuestionQueue.next_unserved(legacy)
            [-1, "2", nil, 9.5].each do |value|
              assert_equal 0, QuestionQueue.served({ "questions" => questions, CURSOR_TEST => value }.merge(window)), value.inspect
            end
            record = { "questions" => questions, CURSOR_TEST => 9 }.merge(window)
            over = QuestionQueue.normalize(record, now: NOW, state_expires_at: NOW.to_f + 1800)

            assert_equal 2, QuestionQueue.served(over)
            assert_nil QuestionQueue.next_unserved(over)
            assert_equal over, QuestionQueue.advance(over)
          end

          private

          def context(now: NOW)
            Contracts::TrustedContext.new(
              organization_id: Characterisation::ORGANIZATION_ID, conversation_key: Characterisation::CONVERSATION_KEY,
              actor_id: Characterisation::ACTOR_ID, account_state: "verified",
              capabilities: Characterisation::CAPABILITIES, now:
            )
          end

          def read = @reads.last

          def pending_report
            { "active_task" => "report_problem", "topic" => "report", "pending_slot" => "category",
              "entities" => { "description" => "rupa u ulici" }, "entity_provenance" => { "description" => "citizen" },
              "draft" => { "reference" => "draft-reference-0007", "revision" => 1, "expires_at" => NOW.to_f + 600 } }
          end

          def conversation(state: nil, &)
            @redis = Characterisation::FakeRedis.new
            @store = StateStore.new(redis: @redis)
            @reads = []
            @model = []
            seed(state) if state
            Characterisation.with_locales(&)
          end

          def seed(attributes)
            seeded = @store.empty_state(context).merge(attributes)
            raise "fixture state rejected" unless @store.write(context:, state: seeded, expected_version: 0) == :saved
          end

          # A task put down mid-conversation, added to the state the previous
          # turns already saved.
          def seed_suspended(task)
            held = @store.read(context:)
            saved = @store.write(context:, state: held.merge("suspended_task" => task, "resume_offered" => true),
                                 expected_version: held.fetch("version"))
            raise "suspended fixture rejected" unless saved == :saved
          end

          def say(text, understanding: RAISING_SPY)
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
            coordinator.call(message: Characterisation::Message.new(text:, conversation_context: [], dialogue_location: nil), context:)
          end

          def understanding_for(action:, topic:, entities:, operation: "start")
            lambda do |**|
              Contracts::Understanding.parse(action:, topic:, entities:, operation:,
                                             needs_clarification: false, secondary: nil, locale: "sr")
            end
          end

          def waste_with_street
            understanding_for(action: "ask_information", topic: "waste",
                              entities: { "query" => "Kad se kupi smeće u Ulici Filipa Višnjića?", "street" => "Filipa Višnjića" })
          end

          def waste_follow_up
            understanding_for(action: "ask_information", topic: "waste", operation: "continue",
                              entities: { "query" => "A kabasti otpad?", "street" => "Filipa Višnjića" })
          end

          # What the model actually returns on such a turn: the new subject,
          # and the retained street handed straight back.
          def parking_echoing_the_street
            understanding_for(action: "ask_information", topic: "parking", operation: "switch",
                              entities: { "query" => "broj za SMS parking u plavoj zoni", "street" => "Filipa Višnjića" })
          end

          def parking_with_street(street)
            understanding_for(action: "ask_information", topic: "parking", operation: "switch",
                              entities: { "query" => "Kako se plaća parking?", "street" => street })
          end
        end
      end
    end
  end
end
