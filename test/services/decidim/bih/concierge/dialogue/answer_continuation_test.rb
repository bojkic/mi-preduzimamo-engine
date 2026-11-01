# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"
require_relative "../../../../../support/decidim/bih/dialogue_characterisation"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # R1 + R2 of the round-2 plan, at the real coordinator boundary.
        #
        # == What is actually being proved
        #
        # Every case below is a CONVERSATION, replayed from the frozen re-test
        # set (docs/audits/2026-09-14-milica-retest/), and the assertion is what
        # the citizen gets on the SECOND turn: the reviewed card they asked
        # about, or the read the reader is handed. Where the answer is a card,
        # its text is asserted, because a card is the whole answer. Where the
        # answer is a read, the READ is asserted — what the host's reader then
        # returns is the host's contract, not this one.
        #
        # The model is a spy that RAISES. A continuation that needed the
        # provider would therefore not be slower, it would come back as the
        # coordinator's "context_unavailable" text, which every assertion here
        # would catch. That is the no-new-model-call proof.
        class AnswerContinuationTest < Minitest::Test
          NOW = Characterisation::NOW
          RAISING_SPY = ->(**) { raise "the model must not be called for a resolved follow-up" }
          SUPPORT = {
            public_support_name: "Lokalna fondacija Bijeljina",
            public_support_email: "office@fondacijabijeljina.com",
            public_support_address: "Nikole Tesle 10, Bijeljina",
            public_support_website: "https://www.fondacijabijeljina.com"
          }.freeze
          READ_FACT = {
            "id" => "fact:1", "kind" => "notice", "text" => "Odgovor iz izvora.", "source_id" => "src",
            "source_label" => "Izvor", "source_url" => "https://example.org/x", "checked_at" => "2026-09-14T09:00:00Z"
          }.freeze

          def setup
            @redis = Characterisation::FakeRedis.new
            @store = StateStore.new(redis: @redis)
            @reads = []
            @model = []
            @read_result = Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 9), facts: [READ_FACT])
            SUPPORT.each { |name, value| Decidim::Bih.define_singleton_method(name) { value } }
          end

          def teardown
            SUPPORT.each_key { |name| Decidim::Bih.singleton_class.send(:remove_method, name) }
          end

          # --- the frozen entity-free follow-ups -----------------------------

          # a8c15 / r8c03 T4. The previous reply literally contained
          # "do 14.10.2026. u 20:00" and the follow-up was answered with the
          # rewards catalogue (and, in r8c03, with river levels).
          def test_a_race_follow_up_is_answered_by_the_race_card_it_continues
            conversation do
              assert_includes say("Šta je trka komšiluka?").reply.text, "14.10.2026"
              answer = say("A kad se završava trka?")

              assert_equal "answered", answer.resolution
              assert_includes answer.reply.text, "14.10.2026. u 20:00"
              assert_empty @reads, "a reviewed card answers without a read"
            end
          end

          # a8c05 T4. "Ko trenutno vodi?" already matched the standings route;
          # "Dobro, a ko trenutno vodi?" did not, and got the rewards catalogue.
          def test_an_acknowledged_follow_up_reaches_the_route_its_bare_form_always_matched
            conversation do
              say("Šta je trka komšiluka?")
              say("Dobro, a ko trenutno vodi?")

              assert_equal "race_standings", read.fetch(:entities).fetch("category")
              assert_equal "launch", read.fetch(:topic)
            end
          end

          # a8c06 T5. The earning reader exists and is precise; the router would
          # not hand it the turn, so the catalogue answered instead.
          def test_an_earning_follow_up_stays_with_the_earning_reader
            conversation do
              say("Koliko bodova nosi volonterski sat?")
              say("A koliko za registraciju?")

              assert_equal "goodwill", read.fetch(:topic)
              assert_equal "earn", read.fetch(:entities).fetch("category")
              assert_includes read.fetch(:entities).fetch("query"), "registraciju"
              assert_includes read.fetch(:entities).fetch("query"), "volonterski sat"
            end
          end

          # a8c02 T2. The fare answer had no place in it, so "a za djecu?" left
          # the reader with two words and it asked for an origin instead.
          def test_a_fare_follow_up_carries_the_question_it_refines
            conversation do
              say("Koliko košta autobuska karta u Bijeljini?", understanding: transport)
              say("a za djecu?")

              assert_equal "transport", read.fetch(:topic)
              assert_includes read.fetch(:entities).fetch("query"), "za djecu"
              assert_includes read.fetch(:entities).fetch("query"), "autobuska karta"
            end
          end

          # a8c01 T3 — the one entity-free case that already passed. The retained
          # waste read carries the citizen's street, so the reader has the
          # context and their own words ARE the question: unchanged, including
          # the query the reader is handed.
          def test_a_located_read_leaves_its_follow_up_exactly_where_it_was
            conversation do
              say("Kad se odvozi smeće u ulici Svetog Save?", understanding: waste_with_street)
              say("a kabasti?", understanding: bulky)

              assert_equal "bulky_waste", read.fetch(:topic)
              assert_equal "a kabasti?", read.fetch(:entities).fetch("query")
            end
          end

          # a8c09 T2/T3 — DEFERRED, deliberately. A three-part opener followed by
          # "A drugo pitanje?" refers to a question that was never answered;
          # the last answered subject cannot recover it, and continuing from
          # that subject would answer the wrong one of the citizen's questions.
          # Queued questions need their own owner.
          def test_a_queued_question_reference_is_declined_rather_than_mis_continued
            ["a drugo pitanje", "a trece", "i trece pitanje"].each do |folded|
              assert TextPredicates.queued_question?(folded), folded
            end
            conversation do
              say("Šta je trka komšiluka?")
              answer = say("A drugo pitanje?", understanding: ->(**) { Contracts::Understanding.clarify(locale: "sr") })

              refute_includes answer.reply.text, "14.10.2026", "the last answered subject is not the queued question"
              assert_equal 1, @model.length, "a queued question goes where it went before"
            end
          end

          # --- the paired cold questions -------------------------------------

          def test_a_cold_follow_up_shaped_question_has_no_retained_subject_to_borrow
            conversation do
              say("A za djecu?", understanding: ->(**) { Contracts::Understanding.clarify(locale: "sr") })

              assert_equal 1, @model.length, "with nothing retained there is nothing to continue from"
            end
          end

          def test_a_cold_race_follow_up_is_not_answered_from_a_card
            assert_nil PublicInformation.card("A kad se završava trka?")
            conversation do
              say("A kad se završava trka?", understanding: ->(**) { Contracts::Understanding.clarify(locale: "sr") })

              assert_equal 1, @model.length
            end
          end

          # The retained subject is not a licence to answer anything with it.
          # "A kad se završava trka?" after a vote-integrity answer shares no
          # word with it, so the invariant card must not be served again.
          def test_a_follow_up_about_something_else_never_re_serves_the_retained_card
            conversation do
              assert_includes say("Da li bodovi utiču na glasanje?").reply.text, "priznanje, ne moć"
              answer = say("A kad se završava trka?", understanding: ->(**) { Contracts::Understanding.clarify(locale: "sr") })

              refute_includes answer.reply.text, "priznanje, ne moć"
              assert_equal 1, @model.length
            end
          end

          # "Šta si ono rekla?" was recognised nowhere and jumped subject.
          def test_a_repeat_request_returns_the_same_answer
            conversation do
              first = say("Šta je trka komšiluka?")

              assert_equal first.reply.text, say("Šta si ono rekla?").reply.text
            end
          end

          # --- the contract the no-state-write test exists for ---------------

          # A pending report, an informational question, a follow-up to it, and
          # then the resume. The draft reference and revision the citizen is
          # looking at must be the same object at the end.
          def test_a_pending_report_survives_a_card_a_follow_up_and_its_resume
            draft = { "reference" => "draft-reference-0001", "revision" => 2, "expires_at" => NOW.to_f + 600 }
            suspended = @store.empty_state(context).slice(*StateStore::TASK_KEYS).merge(
              "active_task" => "report_problem", "topic" => "report", "pending_slot" => "category",
              "entities" => { "description" => "rupa u ulici" }, "entity_provenance" => { "description" => "citizen" },
              "draft" => draft
            )
            conversation(state: { "active_task" => "ask_information", "topic" => "goodwill", "suspended_task" => suspended }) do
              say("Šta je trka komšiluka?")
              assert_includes say("A kad se završava trka?").reply.text, "14.10.2026"

              held = @store.read(context:).fetch("suspended_task")

              assert_equal draft, held.fetch("draft")
              assert_equal "category", held.fetch("pending_slot")

              say("nastavi", understanding: ->(**) { Contracts::Understanding.clarify(locale: "sr") })
              resumed = @store.read(context:)

              assert_equal "report_problem", resumed.fetch("active_task")
              assert_equal draft, resumed.fetch("draft")
              assert_equal "draft-reference-0001", resumed.fetch("draft").fetch("reference")
              assert_equal 2, resumed.fetch("draft").fetch("revision")
              assert_nil resumed.fetch("suspended_task")
            end
          end

          # --- precedence -----------------------------------------------------

          def test_safety_cancellation_and_an_explicit_new_subject_all_outrank_a_continuation
            conversation do
              say("Šta je trka komšiluka?")

              assert_equal "safety", say("Komšiji gori kuća, koga da zovem?").reply.answer_intent
              assert_equal "cancelled", say("odustani").resolution
            end
            conversation do
              say("Šta je trka komšiluka?")
              say("Ima li dežurna apoteka noćas?")

              assert_equal "health", read.fetch(:topic), "an explicit new subject keeps its own route"
            end
          end

          # --- R2: a repair carries information ------------------------------

          # r2c23 T2: the same question came back with 512 more characters of
          # parking. The negated subject is dropped before the positive half is
          # answered, so it cannot be re-served — and the model is not primed
          # with it either.
          #
          # R6 CHANGED WHAT "the rest" IS ANSWERED WITH, and this case was
          # updated rather than left to pass by accident. The positive half now
          # reaches a reviewed card: "who runs this platform and is it free"
          # here, and on a host that configures a funder statement — every real
          # deployment — the funding card, which answers "ko je finansira"
          # outright (PublicInformationTest#
          # test_the_new_cards_answer_at_the_coordinator_with_the_model_forbidden).
          # What R2 owns is unchanged and is what the assertions below hold: the
          # negated subject is dropped, never re-read and never retained.
          def test_negating_the_answered_topic_drops_it_and_answers_the_rest
            conversation do
              say("Da li je ovo besplatno? Ko plaća ovo?", understanding: parking)
              say("Ne pitam za parking. Pitam da li je korišćenje ove platforme besplatno i ko je finansira.",
                  understanding: ->(**) { Contracts::Understanding.clarify(locale: "sr") })

              refute_equal "parking", @model.last.fetch(:state).fetch("topic")
              assert_nil @model.last.fetch(:state).fetch("active_task")
              assert_equal 1, @reads.length, "no second parking read"
              [@model.last.fetch(:state)[StateStore::ANSWER_CONTEXT_KEY],
               @store.read(context:).fetch(StateStore::ANSWER_CONTEXT_KEY)].compact.each do |retained|
                refute_match(/parking/i, retained.fetch("anchor"),
                             "the negated subject must never be retained as what was answered")
              end
            end
          end

          # r5c02 T5: negating the FACET keeps the subject. The positive half is
          # answered inside it, with no clarifying turn and no model call.
          def test_negating_a_facet_keeps_the_subject_and_answers_without_a_clarifying_turn
            conversation do
              say("Koliko košta autobuska karta u Bijeljini?", understanding: transport)
              answer = say("Ne pitam za liniju. Pitam koliko košta karta za dijete.")

              assert_equal "answered", answer.resolution
              assert_equal "transport", read.fetch(:topic)
              assert_includes read.fetch(:entities).fetch("query"), "za dijete"
              assert_includes read.fetch(:entities).fetch("query"), "autobuska karta"
              refute_includes read.fetch(:entities).fetch("query"), "liniju"
            end
          end

          # Only ask when nothing is recoverable. A bare repair names no subject
          # and carries no request, so it still asks — and asks for one thing.
          def test_a_bare_repair_still_asks_because_nothing_is_recoverable
            conversation do
              say("Da li bodovi utiču na glasanje?")
              answer = say("Nisam to pitala.")

              assert_equal "clarification", answer.resolution
              assert_equal I18n.t("decidim.bih.dialogue.repair_clarify", locale: :sr), answer.reply.text
            end
          end

          # A correction re-aims a question. It never reaches past one into an
          # unfinished report: the draft holds the reference the citizen is
          # looking at, so the report path keeps its own repair.
          def test_a_correction_never_touches_a_live_draft
            draft = { "reference" => "draft-reference-0002", "revision" => 1, "expires_at" => NOW.to_f + 600 }
            conversation(state: { "active_task" => "report_problem", "topic" => "report", "pending_slot" => "category",
                                  "entities" => { "description" => "rupa" }, "entity_provenance" => { "description" => "citizen" },
                                  "draft" => draft }) do
              say("Ne pitam za parking. Pitam koliko košta karta.",
                  understanding: ->(**) { Contracts::Understanding.clarify(locale: "sr") })
              after = @store.read(context:)

              assert_equal draft, after.fetch("draft")
              assert_equal "report_problem", after.fetch("active_task")
              assert_equal "rupa", after.fetch("entities").fetch("description")
            end
          end

          # "Ne," in front of a request negates the ANSWER, not the request. The
          # newcomer question keeps its reviewed card; treating the second
          # sentence as the request would have answered "Prvi put sam ovdje."
          def test_a_discourse_no_in_front_of_a_request_is_not_a_correction
            assert_nil TextPredicates.contrastive_correction("Ne, pitam šta je MI PRE(D)UZIMAMO? Prvi put sam ovdje.")
            conversation do
              answer = say("Ne, pitam šta je MI PRE(D)UZIMAMO? Prvi put sam ovdje.")

              assert_equal "answered", answer.resolution
              assert_includes answer.reply.text, "MI PRE(D)UZIMAMO!"
            end
          end

          # r8c02 T2: a repair whose positive half a reviewed card already
          # answers keeps the card. The correction path never sees it.
          def test_a_repair_whose_request_a_card_answers_keeps_the_card
            conversation do
              say("Ako imam više bodova, da li moj glas više vrijedi?")
              answer = say("Nisam to pitala. Pitam da li bodovi zajedništva utiču na težinu mog glasa?")

              assert_equal "answered", answer.resolution
              assert_includes answer.reply.text, "priznanje, ne moć"
            end
          end

          # A correction may not swallow a danger. Safety is decided in
          # Coordinator#call, before the correction, and the danger words here
          # are in the half the citizen DID ask.
          def test_a_danger_inside_a_correction_is_still_answered_as_a_danger
            conversation do
              answer = say("Ne tražim vijesti. Plamen se upravo širi prema zgradi, koga odmah da zovem?")

              assert_equal "safety", answer.reply.answer_intent
            end
          end

          # Move 3 only carries a true ellipsis. A follow-up with room to name
          # its own subject is not one, and carrying the fare question into an
          # account question would answer neither.
          def test_a_follow_up_long_enough_to_name_its_own_subject_is_not_carried
            conversation do
              say("Koliko košta autobuska karta u Bijeljini?", understanding: transport)
              say("A šta ako još nemam nalog?", understanding: ->(**) { Contracts::Understanding.clarify(locale: "sr") })

              assert_equal 2, @model.length, "the retained fare question is not carried into an account question"
            end
          end

          # The control from the current-question trace: a negated action INSIDE
          # a positive request is not a correction and never was.
          def test_a_negated_action_inside_a_positive_request_is_not_a_correction
            ["Treba mi službena stranica toplane, ne prijava problema.",
             "Hoću kontakt Vodovoda, ne prijavu kvara",
             "Kad se odvozi smeće?"].each do |text|
              assert_nil TextPredicates.contrastive_correction(text), text
            end
          end

          # --- the retained record itself -------------------------------------

          def test_the_key_is_versioned_outside_the_suspended_task_and_empty_by_default
            assert_equal "answer_context_v1", AnswerContext::KEY
            assert_includes StateStore::STATE_KEYS, AnswerContext::KEY
            refute_includes StateStore::TASK_KEYS, AnswerContext::KEY, "a suspended task must never carry a retained answer"
            assert_nil @store.empty_state(context).fetch(AnswerContext::KEY)
            assert_equal StateStore::TASK_KEYS.sort, (Coordinator::FRESH_TASK.keys + ["locale"]).sort
          end

          # The legacy read adapter is the third answering path, and it saves
          # its own task already — the retained answer rides that SAME CAS
          # write, so an answered legacy read still costs exactly one.
          def test_a_legacy_read_retains_its_subject_in_its_own_single_write
            conversation do
              answer = say("Šta su bodovi zajedništva?", understanding: legacy_switch, legacy: true)

              assert_equal "answered", answer.resolution
              retained = @store.read(context:).fetch(AnswerContext::KEY)

              assert_equal "legacy_read", retained.fetch("kind")
              assert_equal "goodwill", retained.fetch("topic")
              assert_equal 1, @store.read(context:).fetch("version"), "exactly one CAS write for the answered turn"
            end
          end

          def test_a_private_account_answer_is_never_retained
            %w(account report neighborhood).each do |topic|
              assert_nil AnswerContext.capture(kind: "core_read", subject: "ask_information:#{topic}", action: "ask_information",
                                               topic:, anchor: "koliko bodova imam", now: NOW, state_expires_at: NOW.to_f + 1800),
                         topic
            end
            assert_nil AnswerContext.capture(kind: "core_read", subject: "report_status:goodwill", action: "report_status",
                                             topic: "goodwill", anchor: "moje prijave", now: NOW, state_expires_at: NOW.to_f + 1800)
          end

          def test_a_credential_shaped_question_is_never_retained_as_an_anchor
            assert_nil AnswerContext.capture(kind: "public_card", subject: "civic_privacy", anchor: "moj kod je 123456",
                                             now: NOW, state_expires_at: NOW.to_f + 1800)
          end

          def test_a_retained_answer_expires_and_is_dropped_on_read
            conversation do
              say("Šta je trka komšiluka?")

              refute_nil @store.read(context:).fetch(AnswerContext::KEY)
              later = context(now: NOW + AnswerContext::TTL + 1)

              assert_nil @store.read(context: later).fetch(AnswerContext::KEY)
              refute_nil @store.read(context: later).fetch("topic"), "only the retained answer expires, not the conversation"
            end
          end

          def test_a_malformed_retained_answer_is_dropped_and_never_raises
            [{ "kind" => "nonsense" }, { "kind" => "public_card" }, "text", 7,
             { "kind" => "core_read", "subject" => "ask_information:waste", "action" => "ask_information",
               "topic" => "waste", "facet" => "nonsense", "anchor" => "x y",
               "opened_at" => NOW.to_f, "expires_at" => NOW.to_f + 60 }].each do |value|
              assert_nil AnswerContext.normalize(value, now: NOW, state_expires_at: NOW.to_f + 1800), value.inspect
            end
          end

          def test_a_real_task_switch_drops_the_retained_answer_with_the_task
            conversation do
              say("Koliko bodova nosi volonterski sat?")

              assert_equal "goodwill", @store.read(context:).fetch(AnswerContext::KEY).fetch("topic")
              # An answered switch REPLACES the retained subject.
              say("Kad se odvozi smeće u ulici Svetog Save?", understanding: waste_with_street)

              assert_equal "waste", @store.read(context:).fetch(AnswerContext::KEY).fetch("topic")
              # A switch that does NOT answer clears it rather than leaving the
              # previous subject reachable from the new task.
              @read_result = Contracts::ReadResult.new(status: "empty")
              say("Koliko košta autobuska karta u Bijeljini?", understanding: transport)

              assert_nil @store.read(context:).fetch(AnswerContext::KEY)
            end
          end

          # --- the brevity request --------------------------------------------

          # r9c02 T4 returned the 957-character Sistem 48 catalogue to a request
          # for two sentences. The wording is now a presentation request, and it
          # continues the retained subject instead of being re-classified.
          def test_a_sentence_count_brevity_request_continues_the_retained_subject
            assert TextPredicates.presentation_request?(Decidim::Bih::Text.fold("Može odgovor u najviše dvije rečenice?"))
            conversation do
              say("Koliko bodova nosi volonterski sat?")
              say("Može odgovor u najviše dvije rečenice?")

              assert_equal "goodwill", read.fetch(:topic), "a brevity request is not a new subject"
              assert_empty @model, "a presentation request never reaches the model"
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

          def read = @reads.last

          # One conversation: one store, one trusted context, every turn sharing
          # the state the previous turn saved.
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

          def say(text, understanding: RAISING_SPY, legacy: false)
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
              state_store: @store, runtime: Characterisation::InlineRuntime.new,
              legacy_secondary: (legacy_adapter if legacy)
            )
            coordinator.call(message: Characterisation::Message.new(text:, conversation_context: [], dialogue_location: nil), context:)
          end

          # A deterministic, read-only legacy responder: no classifier, no
          # write port, exactly what LegacyReadAdapter is allowed to wrap.
          def legacy_adapter
            responder = Object.new
            responder.define_singleton_method(:respond) do |_message|
              Responder::Reply.new(text: "Nagrada A: opis. Cijena u bodovima: 100.\n\nIzvor: Bodovnik",
                                   report: nil, answer_intent: "goodwill", tone: "core")
            end
            Coordinator::LegacyReadAdapter.new(responder:)
          end

          def legacy_switch
            lambda do |**|
              Contracts::Understanding.parse(action: "ask_information", topic: "goodwill",
                                             entities: { "query" => "sta su bodovi zajednistva" }, operation: "switch",
                                             needs_clarification: false, secondary: nil, locale: "sr")
            end
          end

          def understanding_for(action:, topic:, entities:)
            lambda do |**|
              Contracts::Understanding.parse(action:, topic:, entities:, operation: "start",
                                             needs_clarification: false, secondary: nil, locale: "sr")
            end
          end

          def transport
            understanding_for(action: "ask_information", topic: "transport",
                              entities: { "query" => "Koliko košta autobuska karta u Bijeljini?" })
          end

          def parking
            understanding_for(action: "ask_information", topic: "parking",
                              entities: { "query" => "Da li je ovo besplatno? Ko plaća ovo?" })
          end

          def waste_with_street
            understanding_for(action: "ask_information", topic: "waste",
                              entities: { "query" => "Kad se odvozi smeće u ulici Svetog Save?", "street" => "Svetog Save" })
          end

          def bulky
            understanding_for(action: "ask_information", topic: "bulky_waste", entities: {})
          end
        end
      end
    end
  end
end
