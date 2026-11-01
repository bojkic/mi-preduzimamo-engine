# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"
require_relative "../../../../../support/decidim/bih/dialogue_characterisation"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # R6 — "kraće" after a reviewed CARD, at the real coordinator boundary.
        #
        # == What is being proved
        #
        # The owner's most-repeated complaint (case r9c02): after a
        # report-privacy card the citizen writes "Može odgovor u najviše dvije
        # rečenice?" and gets the 957-character Sistem 48 catalogue — a
        # different subject, longer than the answer they asked to shorten.
        #
        # Every conversation below asserts the SECOND turn, and the assertion
        # is the same shape each time: the same card, never longer. The model
        # is a spy that records every call, so "the turn was re-classified from
        # scratch" is directly observable rather than inferred; where a case is
        # about a turn that SHOULD still reach the provider, the spy proves
        # that too.
        class CardPresentationTest < Minitest::Test
          NOW = Characterisation::NOW
          RAISING_SPY = ->(**) { raise "the model must not be called for a presentation request about a card" }
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
          # What the model came back with in r9c02: a different subject
          # entirely. Any case below that reaches it is answered from this, so
          # a regression shows up as the catalogue rather than as a card.
          CATALOGUE = lambda do |**|
            Contracts::Understanding.parse(action: "ask_information", topic: "sistem48",
                                           entities: { "query" => "sistem 48" }, operation: "start",
                                           needs_clarification: false, secondary: nil, locale: "sr")
          end

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

          # --- the defect, for both card registries --------------------------

          # r9c02. The report card left NOTHING behind — ReportGuidanceStage
          # returned the state untouched — so the brevity request had no
          # subject to land on at all.
          def test_explicit_script_request_changes_card_script_and_retains_preference
            conversation do
              say("Šta je trka komšiluka?")
              answer = say("Молим ћирилицом")
              assert_equal "sr-Cyrl", answer.reply.locale
              assert_match(/\p{Cyrillic}/, answer.reply.text)
              latin = say("Napiši latinicom")
              assert_equal "sr", latin.reply.locale
              refute_match(/\p{Cyrillic}/, latin.reply.text)
              assert_empty @model
            end
          end

          def test_vote_integrity_modifier_uses_reviewed_brief_copy_and_keeps_rules_link
            conversation do
              first = say("Može li moj glas vrijediti više ako skupim bodove?")
              second = say("Kratko i jasno odvoji bodove od glasa.")
              assert_equal "answered", second.resolution
              assert_operator second.reply.text.length, :<, first.reply.text.length
              assert_includes second.reply.text, "/biceriseno/zajednistvo?tab=kako"
              assert_includes second.reply.text, "jedan glas"
              assert_empty @model
            end
          end

          def test_a_brevity_request_after_a_report_card_is_answered_by_that_card
            conversation do
              card = say("Ko vidi moju prijavu kada je pošaljem?")
              answer = say("Može odgovor u najviše dvije rečenice?", understanding: CATALOGUE)

              assert_equal "answered", answer.resolution
              assert_equal "report_guidance", answer.reply.answer_intent
              assert_includes answer.reply.text, "Nije javno:"
              assert_operator answer.reply.text.length, :<=, card.reply.text.length,
                              "a shortened answer is never longer than the answer it shortened"
              assert_empty @model, "a presentation request about a card never reaches the model"
              assert_empty @reads, "re-serving reviewed copy performs no read"
            end
          end

          # The same gap for a PUBLIC card: it did retain an answer context,
          # but a card may carry no action/topic, and the coordinator's
          # presentation_subject reads exactly those two fields.
          def test_a_brevity_request_after_a_public_card_shortens_that_card
            conversation do
              card = say("Šta je trka komšiluka?")
              answer = say("kraće", understanding: CATALOGUE)

              assert_equal "answered", answer.resolution
              assert_equal "launch", answer.reply.answer_intent
              assert_includes answer.reply.text, "14.10.2026", "the same card, on the same subject"
              assert_operator answer.reply.text.length, :<, card.reply.text.length,
                              "the card was rendered to a tighter budget"
              assert_empty @model
            end
          end

          # The wording the owner actually used, against a public card, and a
          # Cyrillic conversation answered in Cyrillic.
          def test_the_brevity_wordings_are_all_answered_on_the_retained_subject
            ["kraće", "ukratko", "Može odgovor u najviše dvije rečenice?", "Molim te kraće."].each do |request|
              conversation do
                card = say("Šta je trka komšiluka?")
                answer = say(request, understanding: CATALOGUE)

                assert_equal "launch", answer.reply.answer_intent, request
                assert_operator answer.reply.text.length, :<=, card.reply.text.length, request
                assert_empty @model, request
              end
            end
          end

          def test_a_cyrillic_brevity_request_is_answered_in_cyrillic
            conversation do
              say("Шта је трка комшилука?")
              answer = say("краће", understanding: CATALOGUE)

              assert_equal "launch", answer.reply.answer_intent
              assert_match(/\p{Cyrillic}/, answer.reply.text)
              assert_empty @model
            end
          end

          # The brevity LEVEL is persisted for a card, so a repeated bare
          # "kraće" steps one budget tighter instead of re-serving the same
          # rendering. It used to: the retention hook wrote the answer context
          # and the conversation clock and nothing else, so every request was
          # computed from the renderer's default and landed on the same level.
          # "još kraće" names the tightest level outright and always reached
          # it, which is why only the REPEAT was broken.
          def test_a_repeated_brevity_request_steps_one_budget_tighter_each_time
            conversation do
              card = say("Šta je trka komšiluka?")
              first = say("kraće", understanding: CATALOGUE)
              again = say("kraće", understanding: CATALOGUE)

              assert_operator first.reply.text.length, :<, card.reply.text.length
              assert_operator again.reply.text.length, :<, first.reply.text.length,
                              "a second kraće is shorter than the first, not identical to it"
              assert_includes again.reply.text, "14.10.2026", "still the same card, on the same subject"
              assert_empty @model, "stepping tighter never reaches the model"
              assert_empty @reads
            end
          end

          # The tightest budget is the FLOOR, not an error: FactRenderer clamps
          # at "brief" and returns the copy it cannot improve on. A third
          # request re-serving the second is the honest answer.
          def test_the_tightest_budget_is_the_floor_and_jos_krace_reaches_it_directly
            conversation do
              say("Šta je trka komšiluka?")
              say("kraće", understanding: CATALOGUE)
              again = say("kraće", understanding: CATALOGUE)
              third = say("kraće", understanding: CATALOGUE)

              assert_equal again.reply.text, third.reply.text, "the tightest budget is a floor, re-served unchanged"
              assert_empty @model
            end

            conversation do
              say("Šta je trka komšiluka?")
              first = say("kraće", understanding: CATALOGUE)
              tightest = say("još kraće", understanding: CATALOGUE)

              assert_operator tightest.reply.text.length, :<, first.reply.text.length
            end
          end

          # The level rides the SAME best-effort retention write as the answer
          # context, under the state store's own key and its own closed token
          # list. A level equal to the renderer's default is stored as nil,
          # exactly as the two answered-turn writers in ProcedureRunner do.
          def test_the_rendered_level_is_retained_under_the_state_stores_own_key
            conversation do
              say("Šta je trka komšiluka?")

              assert_nil @store.read(context:).fetch(StateStore::PRESENTATION_LEVEL_KEY),
                         "a cold card asked for no level, so none is written"

              say("kraće", understanding: CATALOGUE)
              state = @store.read(context:)

              assert_equal "short", state.fetch(StateStore::PRESENTATION_LEVEL_KEY)
              assert_equal "public_card", state.fetch(AnswerContext::KEY).fetch("kind"),
                           "the answer context is retained in the same write"

              say("kraće", understanding: CATALOGUE)

              assert_equal "brief", @store.read(context:).fetch(StateStore::PRESENTATION_LEVEL_KEY)
            end
          end

          # A refused CAS must cost the citizen the remembered PREFERENCE and
          # never the ANSWER: retention is best effort, and routing it through
          # turn.accept instead would turn a lost race into a failure reply on
          # a card that was already rendered correctly.
          def test_a_refused_retention_still_answers_with_the_card
            conversation do
              card = say("Šta je trka komšiluka?")
              @store.define_singleton_method(:write) { |**| :conflict }
              answer = say("kraće", understanding: CATALOGUE)

              assert_equal "answered", answer.resolution
              assert_equal "launch", answer.reply.answer_intent
              assert_operator answer.reply.text.length, :<, card.reply.text.length
              assert_empty @model
            end
          end

          # --- what must NOT change ------------------------------------------

          # No retained answer and no open task: there is nothing to shorten,
          # and a card must never be invented out of nothing. This is the turn
          # that still belongs to the provider.
          def test_a_brevity_request_with_nothing_retained_still_reaches_the_model
            conversation do
              answer = say("kraće", understanding: CATALOGUE)

              assert_equal 1, @model.length, "with no subject, the turn is still the provider's"
              assert_equal "sistem48", @reads.last.fetch(:topic), "and nothing else claims it"
              refute_includes answer.reply.text, "14.10.2026"
            end
          end

          # The OPEN TASK owns a brevity request — Coordinator#presentation_subject's
          # first branch. A card answered mid-task deliberately writes no task
          # state, so both records exist at once and the task must still win.
          def test_an_open_task_still_owns_a_brevity_request_over_a_retained_card
            conversation do
              say("Koliko košta autobuska karta?", understanding: transport)
              say("Šta je trka komšiluka?")
              before = @reads.length
              answer = say("kraće")

              assert_operator @reads.length, :>, before, "the open task is re-rendered, not the card"
              assert_equal "transport", @reads.last.fetch(:topic)
              refute_includes answer.reply.text, "14.10.2026"
            end
          end

          # The retained answer lives ten minutes (AnswerContext::TTL) inside a
          # thirty-minute conversation. Eleven minutes later the conversation is
          # still alive and the card is not: the turn goes back to the provider
          # rather than re-serving stale copy.
          def test_a_retained_report_card_expires_and_the_turn_returns_to_the_model
            conversation do
              say("Ko vidi moju prijavu kada je pošaljem?")
              later = NOW + (11 * 60)

              assert_nil @store.read(context: context(now: later))[AnswerContext::KEY], "the retained card expired"

              answer = say("Može odgovor u najviše dvije rečenice?", understanding: CATALOGUE, now: later)

              assert_equal 1, @model.length, "an expired subject is not a subject"
              refute_includes answer.reply.text, "Nije javno:"
            end
          end

          # An emergency is decided in Coordinator#call, before any stage runs.
          # The word "kraće" must not change that.
          def test_a_danger_message_after_a_card_is_still_answered_as_danger
            conversation do
              say("Ko vidi moju prijavu kada je pošaljem?")
              answer = say("Gori mi kuća, kraće!", understanding: CATALOGUE)

              refute_includes answer.reply.text, "Nije javno:"
            end
          end

          # --- what the record may hold --------------------------------------

          # A card is reviewed copy, not a read: the record names the card and
          # keeps the citizen's own question, and carries no read identity at
          # all. That is also what makes the private families un-bypassable.
          def test_a_retained_report_card_carries_no_read_identity
            conversation do
              say("Ko vidi moju prijavu kada je pošaljem?")
              retained = @store.read(context:).fetch(AnswerContext::KEY)

              assert_equal "report_card", retained.fetch("kind")
              assert_equal "report_visibility", retained.fetch("subject")
              assert_equal "Ko vidi moju prijavu kada je pošaljem?", retained.fetch("anchor")
              assert_nil retained.fetch("action")
              assert_nil retained.fetch("topic")
            end
          end

          # Drop, never raise: every one of these is refused and returns nil.
          def test_a_card_that_carries_a_private_read_identity_is_dropped
            %w(public_card report_card).each do |kind|
              assert_nil capture(kind:, subject: "report_visibility", action: "report_problem", topic: "report"),
                         "#{kind} may not carry a read identity, private or otherwise"
              assert_nil capture(kind:, subject: "report_visibility", action: "ask_information", topic: "waste"),
                         "#{kind} may not carry a read identity at all"
            end
          end

          # Unchanged by the new kind: a READ about this citizen is still never
          # retained, whichever of the two families it belongs to.
          def test_a_private_read_is_still_never_retained
            assert_nil capture(kind: "core_read", subject: "ask_information:report", action: "ask_information", topic: "report")
            assert_nil capture(kind: "core_read", subject: "report_status:waste", action: "report_status", topic: "waste")
            assert_nil capture(kind: "core_read", subject: "ask_information:neighborhood", action: "ask_information", topic: "neighborhood")
            refute_nil capture(kind: "core_read", subject: "ask_information:waste", action: "ask_information", topic: "waste"),
                       "a public read is still retained"
          end

          # --- the load cycle ------------------------------------------------

          # These files load in a require cycle — report_guidance requires
          # pre_model_stages, which requires card_presentation_stage, which
          # needs ReportGuidance — and ZEITWERK picks the entry point: in
          # production the first reference to Decidim::…::ReportGuidance loads
          # report_guidance.rb directly, opening the cycle from the one side
          # where the constant is not yet defined. That raised NameError at
          # boot and no in-process test could see it, because every test file
          # here enters through coordinator.rb. Each entry point therefore
          # loads in a process of its own.
          def test_every_dialogue_entry_point_loads_the_whole_cycle
            root = File.expand_path("../../../../../../app/services/decidim/bih/concierge/dialogue", __dir__)
            # public_information_stage.rb is deliberately NOT in this list: it
            # is the one stage file with no +require_relative "pre_model_stages"+
            # of its own and it cannot simply be given one, because
            # account_phone_visibility_stage anchors +before:
            # "public_information_card"+ — a stage that file has not registered
            # yet when it opens the cycle. That is a pre-existing structural
            # limit of the seam's anchors, unrelated to this change and not
            # reachable today (nothing resolves PublicInformationStage first).
            %w(report_guidance card_presentation_stage pre_model_stages coordinator).each do |entry|
              script = "require #{File.join(root, entry).inspect}; " \
                       "print 'OK:' + Decidim::Bih::Concierge::Dialogue::PreModelStages.stage_names.last"
              output = IO.popen([RbConfig.ruby, "-e", script], err: [:child, :out], &:read)

              assert_includes output, "OK:card_presentation", "#{entry}.rb as the entry point produced: #{output}"
            end
          end

          # --- the two registries stay apart ---------------------------------

          def test_a_card_name_is_only_ever_resolved_against_its_own_registry
            assert_equal ReportGuidance::VISIBILITY, CardPresentation.card_for("report_card", "report_visibility")
            assert_equal PublicInformation::RACE_OVERVIEW, CardPresentation.card_for("public_card", "race_overview")
            assert_nil CardPresentation.card_for("public_card", "report_visibility")
            assert_nil CardPresentation.card_for("report_card", "race_overview")
            assert_nil CardPresentation.card_for("core_read", "report_visibility")
          end

          # A report card is retained for the presentation move and for nothing
          # else: AnswerContinuation cannot continue one, so a follow-up after
          # one is not re-anchored into a subject nobody asked about.
          def test_a_retained_report_card_is_invisible_to_the_continuation_moves
            conversation do
              say("Ko vidi moju prijavu kada je pošaljem?")
              state = @store.read(context:)

              assert_equal "report_card", state.fetch(AnswerContext::KEY).fetch("kind")
              assert_nil AnswerContinuation.resolve(text: "A kad se završava trka?", state:)
            end
          end

          private

          def capture(kind:, subject:, action:, topic:)
            AnswerContext.capture(kind:, subject:, action:, topic:, anchor: "Ko vidi moju prijavu?",
                                  now: NOW, state_expires_at: NOW.to_f + Contracts::CONTEXT_TTL)
          end

          def context(now: NOW)
            Contracts::TrustedContext.new(
              organization_id: Characterisation::ORGANIZATION_ID, conversation_key: Characterisation::CONVERSATION_KEY,
              actor_id: Characterisation::ACTOR_ID, account_state: "verified",
              capabilities: Characterisation::CAPABILITIES, now:
            )
          end

          def transport
            lambda do |**|
              Contracts::Understanding.parse(action: "ask_information", topic: "transport",
                                             entities: { "query" => "Koliko košta autobuska karta?" }, operation: "start",
                                             needs_clarification: false, secondary: nil, locale: "sr")
            end
          end

          # One conversation: one store, one trusted context, every turn sharing
          # the state the previous turn saved.
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
