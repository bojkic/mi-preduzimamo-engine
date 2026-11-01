# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"
require_relative "../../../../../support/decidim/bih/dialogue_characterisation"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # The reviewed public-information cards, at the real coordinator
        # boundary, with the model FORBIDDEN.
        #
        # The understanding lambda raises. A card that needs the provider would
        # therefore not merely be slower — it would return the coordinator's
        # "context_unavailable" failure text instead of the answer, which every
        # assertion below would catch. That is the zero-model-call proof.
        #
        # Scenario ids are from docs/operations/milica-baseline-freeze-2026-09-14.md.
        class PublicInformationTest < Minitest::Test
          NOW = Characterisation::NOW
          CONVERSATION_KEY = Characterisation::CONVERSATION_KEY
          # Reaching the provider is itself the failure this suite is about.
          RAISING_SPY = ->(**) { raise "the model must not be called for a reviewed public-information card" }

          SUPPORT = {
            public_support_name: "Lokalna fondacija Bijeljina",
            public_support_email: "office@fondacijabijeljina.com",
            public_support_address: "Nikole Tesle 10, Bijeljina",
            public_support_website: "https://www.fondacijabijeljina.com"
          }.freeze

          def setup
            @redis = Characterisation::FakeRedis.new
            @store = StateStore.new(redis: @redis)
            SUPPORT.each { |name, value| Decidim::Bih.define_singleton_method(name) { value } }
          end

          def teardown
            SUPPORT.each_key { |name| Decidim::Bih.singleton_class.send(:remove_method, name) }
          end

          def test_feedback_meaning_reaches_the_real_coordinator_without_registration_or_a_model
            ["Šta znači ako odgovor označim kao Nije korisno?",
             "Čemu služi dugme Korisno ispod tvog odgovora?"].each do |question|
              result = answer(question)
              assert_equal "answered", result.resolution
              assert_includes result.reply.text, "ocjenu"
              assert_includes result.reply.text, "ne objavljuje javno"
              refute result.handoff_offered
              assert_nil result.reply.report
            end
          end

          def test_feedback_explanation_does_not_consume_a_correction_or_typed_praise
            ["Nije korisno; kako se koristi SMS parking?",
             "Nije korisno, pitao sam za redovan odvoz, ne želim da prijavim problem.",
             "Korisno, hvala. Kada dolazi sljedeći autobus?",
             "Označio sam Nije korisno jer još ne znam koju zonu da platim."].each do |question|
              refute_equal "civic_feedback", PublicInformation.card(question)&.name
            end
          end

          # --- selection, as a pure function ---------------------------------

          # MS-B2C02, MS-B2C08, MS-B2C09, MS-B2C36 and the sneaky variant the
          # review recorded: every one of these was answered without ever
          # saying no.
          def test_vote_integrity_questions_select_the_invariant_card
            [
              "Ako imam više bodova, da li moj glas više vrijedi?",
              "Pitam da li bodovi zajedništva utiču na težinu mog glasa?",
              "Da li bodovi utiču na glasanje?",
              "A da li podižu rang mog prijedloga?",
              "Da li neko sa 1000 bodova ima veću glasačku moć od mene sa 20?",
              "Да ли моји бодови помјерају приједлог на врх листе?",
              "Значи ни видљивост приједлога не зависи од бодова?",
              "Isplati li se skupljati bodove da mi prijedlog bude viđeniji?",
              "Vrati se na bodove: da li utiču na glasanje?",
              "Da li donacije daju veću težinu glasu?",
              "Does having more points make my vote count more?"
            ].each { |text| assert_equal PublicInformation::VOTE_INTEGRITY, PublicInformation.card(text), text }
          end

          # MS-B3C10, MS-B3C11, MS-B3C34 and the a4c11 "do you sell my data"
          # turn that used to return the bot's own systems inventory.
          def test_privacy_questions_select_the_privacy_card
            [
              "Gdje mogu pročitati politiku privatnosti ove platforme?",
              "Šta radite s mojim podacima? Da li ih prodajete?",
              "Da li prodajete moje podatke?",
              "Pitam da li moj broj telefona i ime dajete nekome — opštini, strankama, oglašivačima?",
              "Da li drugi građani vide broj telefona s mog naloga?",
              "Гдје пише ваша политика приватности?",
              "Where is your privacy policy?"
            ].each { |text| assert_equal PublicInformation::PRIVACY, PublicInformation.card(text), text }
          end

          # MS-B2C04, MS-B2C34. "MI PRE(D)UZIMAMO" folds to "mi pre d uzimamo",
          # so the brand arrives without its punctuation.
          def test_newcomer_questions_select_the_introduction_card
            [
              "Ko ste vi?",
              "Ne, pitam šta je MI PRE(D)UZIMAMO? Prvi put sam ovdje.",
              "Ništa od toga. Objasni mi čime se bavi ova platforma.",
              "Šta mogu da uradim ovdje?",
              "Prvi put sam na MI, zanima me šta mogu da uradim za svoj kraj.",
              "Ко сте ви?",
              "Who are you?"
            ].each { |text| assert_equal PublicInformation::NEWCOMER, PublicInformation.card(text), text }
          end

          # MS-B2C16, MS-B2C17, MS-B2C18, MS-B2C19 — the four launch turns that
          # were answered with the rewards catalogue or with a Grad Bijeljina
          # public call.
          def test_launch_policy_questions_select_the_matching_facet
            {
              "Da li se za pozivnicu za lansiranje oduzima 20 bodova?" => PublicInformation::LAUNCH_NOT_SPENT,
              "Ako ne potvrdim dolazak u roku od 72 sata, da li mi pozivnica propada?" => PublicInformation::LAUNCH_CONFIRMATION,
              "Da li je potvrda dolaska uslov za ulaz ili samo molba za pozivnicu?" => PublicInformation::LAUNCH_CONFIRMATION,
              "Do kada mogu steći pravo na pozivnicu za 17. septembar?" => PublicInformation::LAUNCH_DEADLINE,
              "Koji je rok za pozivnicu?" => PublicInformation::LAUNCH_DEADLINE,
              "Mogu li dobiti pozivnicu bez registracije ako dođem ranije?" => PublicInformation::LAUNCH_ELIGIBILITY,
              "A ako za pozivnicu pokažem samo e-mail, bez potvrđenog telefona?" => PublicInformation::LAUNCH_ELIGIBILITY
            }.each { |text, card| assert_equal card, PublicInformation.card(text), text }
          end

          # MS-B2C03, MS-B2C20, MS-B2C21, MS-B2C22, MS-B2C35.
          def test_race_questions_select_the_race_cards
            assert_equal PublicInformation::RACE_OVERVIEW, PublicInformation.card("Kako se boduje trka komšiluka?")
            assert_equal PublicInformation::RACE_OVERVIEW, PublicInformation.card("Како се рачуна трка комшилука?")
            assert_equal PublicInformation::RACE_PRIZE, PublicInformation.card("Koliko para dobija komšiluk koji pobijedi u trci?")
            assert_equal PublicInformation::RACE_PRIZE, PublicInformation.card("Kakva je nagrada u trci komšiluka?")
          end

          # MS-B2C26..MS-B2C29 — a6c10/a6c11 answered the foundation's address
          # with "I have no verified fact" and its phone with the municipality's
          # switchboard.
          def test_foundation_contact_questions_select_the_foundation_cards
            assert_equal PublicInformation::FOUNDATION_PHONE, PublicInformation.card("Koji je telefon Lokalne fondacije Bijeljina?")
            assert_equal PublicInformation::FOUNDATION_PHONE, PublicInformation.card("Daj mi broj Fondacije.")
            assert_equal PublicInformation::FOUNDATION_CONTACT, PublicInformation.card("Koja je adresa Fondacije?")
            assert_equal PublicInformation::FOUNDATION_CONTACT, PublicInformation.card("Gdje se nalazi Lokalna fondacija Bijeljina?")
            assert_equal PublicInformation::FOUNDATION_CONTACT, PublicInformation.card("Koji je mejl Fondacije?")
          end

          # The controls. Each of these belongs to another answer path, and a
          # card that swallowed one would be an over-broad pattern passing as a
          # fix. MS-B2C07, MS-B2C14, MS-B3C02, MS-B3C07, MS-B1C20.
          def test_neighbouring_questions_are_left_to_their_own_paths
            [
              "Kako da zaradim bodove",
              "Koliko bodova nosi prijava problema",
              "Koje nagrade mogu dobiti?",
              "moji bodovi",
              "moj rang",
              "Ima li otvorenih javnih poziva?",
              "Kada istice javni poziv za stipendije?",
              "Do kada traje konkurs za subvencije za MSP?",
              "Ko vidi moju prijavu kada je pošaljem?",
              "Mogu li prijaviti problem anonimno?",
              "Zašto je potreban broj telefona za registraciju?",
              "Kada se odvozi smeće u Dvorovima?",
              "Jesam li pozvan na 17.9?",
              "kada je lansiranje platforme",
              "moj broj rezervacije",
              "Ko je predsjednik mz Janja",
              "Šta ima novo?",
              "Kako mogu donirati?"
            ].each { |text| assert_nil PublicInformation.card(text), text }
          end

          def test_selection_refuses_long_text_and_non_strings
            assert_nil PublicInformation.card("Da li bodovi utiču na glasanje? #{"a" * 200}")
            assert_nil PublicInformation.card(nil)
            assert_nil PublicInformation.card("   ")
          end

          # --- the same answers at the coordinator boundary -------------------

          def test_every_card_answers_with_the_model_forbidden
            expectations = {
              "Da li bodovi utiču na glasanje?" => ["priznanje, ne moć", "ne utiču na glasanje"],
              "Da li prodajete moje podatke?" => ["politici privatnosti", "office@fondacijabijeljina.com"],
              "Ko ste vi?" => ["MI PRE(D)UZIMAMO!", "Lokalna fondacija Bijeljina"],
              "Ako ne potvrdim dolazak u roku od 72 sata, da li mi pozivnica propada?" => ["molba, ne uslov", "ne propada"],
              "Do kada mogu steći pravo na pozivnicu?" => ["16.9.2026", "23:59"],
              "Kako se boduje trka komšiluka?" => ["registrovani × 1", "5 prijava i 3 prijedloga"],
              "Koji je telefon Lokalne fondacije Bijeljina?" => ["nije objavljen", "Nikole Tesle 10, Bijeljina", "Gradskoj upravi"]
            }
            expectations.each do |prompt, fragments|
              result = answer(prompt)

              assert_equal "answered", result.resolution, prompt
              fragments.each { |fragment| assert_includes result.reply.text, fragment, prompt }
            end
          end

          # Every card, in every language the dialogue supports, with the copy
          # actually rendered — a missing key or a missing interpolation shows
          # up here rather than in front of a citizen.
          def test_every_card_renders_in_every_supported_locale
            cards = [
              PublicInformation::VOTE_INTEGRITY, PublicInformation::PRIVACY, PublicInformation::NEWCOMER,
              PublicInformation::LAUNCH_NOT_SPENT, PublicInformation::LAUNCH_CONFIRMATION,
              PublicInformation::LAUNCH_DEADLINE, PublicInformation::LAUNCH_ELIGIBILITY,
              PublicInformation::RACE_OVERVIEW, PublicInformation::RACE_PRIZE,
              PublicInformation::FOUNDATION_CONTACT, PublicInformation::FOUNDATION_PHONE,
              # R5/R6. FUNDING and PROPOSAL_ROUTE quote a fact only the host
              # has, so they are rendered in their own case below.
              PublicInformation::PLATFORM_OPERATOR, PublicInformation::IDENTITY,
              PublicInformation::CHAT_MESSAGING, PublicInformation::PHONE_CHANGE
            ]
            Characterisation.with_locales do
              Contracts::LOCALES.each do |locale|
                cards.each do |card|
                  text = PublicInformation.answer(card, locale:)

                  refute_nil text, "#{card.name}/#{locale}"
                  refute_empty text.strip, "#{card.name}/#{locale}"
                  refute_match(/translation missing|%\{/, text, "#{card.name}/#{locale}")
                end
                chips = PublicInformation.quick_replies(PublicInformation::NEWCOMER, locale:)

                assert chips.length.between?(2, 4), "#{locale}: #{chips.length} choices"
                chips.each { |chip| assert chip.fetch(:url).start_with?("/"), chip.inspect }
              end
            end
          end

          # The sharpest form of the zero-model proof: the provider does not just
          # go unused, it is DOWN. A control question on the same coordinator
          # degrades to the provider-unavailable reply, so the cards are not
          # passing because the provider silently worked.
          def test_the_cards_answer_while_the_provider_is_unavailable
            context = trusted_context
            down = ->(**) { raise Understand::ProviderUnavailable, "provider down" }

            ["Da li bodovi uticu na glasanje?", "Da li prodajete moje podatke?", "Ko ste vi?"].each do |text|
              result = answer(text, context:, understanding: down)

              assert_equal "answered", result.resolution, text
            end

            control = answer("Kada se odvozi smece u Dvorovima?", context:, understanding: down)

            assert_equal "unsupported", control.resolution
            assert_equal "fallback", control.reply.answer_intent
          end

          def test_a_cyrillic_question_is_answered_in_cyrillic
            result = answer("Да ли бодови утичу на гласање?")

            assert_includes result.reply.text, "признање, не моћ"
            assert_equal "answered", result.resolution
          end

          # The corpus failure that made this a routing defect and not a
          # phrasing one: b2c19 asked for the invitation cutoff and was handed
          # an SME public call closing 17.09.2026.
          def test_the_invitation_deadline_never_carries_a_public_call_deadline
            text = answer("Do kada mogu steći pravo na pozivnicu za 17. septembar?").reply.text

            assert_includes text, "16.9.2026"
            refute_includes text, "17.09.2026"
            refute_includes text, "2.10.2026"
            refute_match(/stipendij|konkurs|javni poziv/i, text)
          end

          # MS-B2C36: the card has to work after an unrelated topic, which is
          # the turn that used to come back as the rewards catalogue.
          def test_a_card_answers_after_another_topic_and_again_before_one
            context = trusted_context
            assert_includes answer("Kako se boduje trka komšiluka?", context:).reply.text, "registrovani × 1"
            assert_includes answer("Kada se odvozi smeće u Dvorovima?", context:).reply.text, ""
            assert_includes answer("Da li bodovi utiču na glasanje?", context:).reply.text, "priznanje, ne moć"
            assert_includes answer("Ko ste vi?", context:).reply.text, "MI PRE(D)UZIMAMO!"
          end

          # A card is an answer, not a task: it starts none, finishes none and
          # consumes none, so an unfinished draft or a pending confirmation is
          # neither taken nor discarded by one.
          #
          # It DOES now record what it answered, in the separate AnswerContext
          # slot, so the next message can be a follow-up to it. That slot is
          # the only thing a card may change, and this pins the rest field by
          # field: every TASK_KEY, the opaque draft (reference AND revision),
          # the suspended task and the retained evidence.
          def test_a_card_writes_no_task_state_and_only_retains_what_it_answered
            context = trusted_context
            suspended = @store.empty_state(context).slice(*StateStore::TASK_KEYS)
                              .merge("active_task" => "ask_information", "topic" => "waste")
            seeded = @store.empty_state(context).merge(
              "active_task" => "report_problem", "topic" => "report", "pending_slot" => "category",
              "entities" => { "description" => "rupa u ulici" }, "entity_provenance" => { "description" => "citizen" },
              "draft" => { "reference" => "draft-reference-0001", "revision" => 2, "expires_at" => NOW.to_f + 600 },
              "suspended_task" => suspended
            )
            assert_equal :saved, @store.write(context:, state: seeded, expected_version: 0)
            before = @store.read(context:)

            assert_includes answer("Da li bodovi utiču na glasanje?", context:).reply.text, "priznanje, ne moć"
            after = @store.read(context:)

            assert_equal before.slice(*StateStore::TASK_KEYS), after.slice(*StateStore::TASK_KEYS)
            assert_equal before.fetch("draft"), after.fetch("draft")
            assert_equal "draft-reference-0001", after.fetch("draft").fetch("reference")
            assert_equal 2, after.fetch("draft").fetch("revision")
            assert_equal before.fetch("suspended_task"), after.fetch("suspended_task")
            assert_equal before.fetch("prior_evidence"), after.fetch("prior_evidence")
            assert_equal "category", after.fetch("pending_slot")
            # The one permitted difference, plus the CAS version that carried
            # it and the conversation clock every answered turn refreshes.
            differences = (before.keys | after.keys).reject { |key| before[key] == after[key] }

            assert_equal [StateStore::ANSWER_CONTEXT_KEY, "version"], (differences - %w(updated_at expires_at)).sort
            assert_equal "civic_vote_integrity", after.fetch(StateStore::ANSWER_CONTEXT_KEY).fetch("subject")
          end

          # A refused CAS loses the continuity hint and keeps the ANSWER: the
          # citizen asked a question the platform has already decided, and a
          # concurrent turn is no reason to refuse them the answer.
          def test_a_card_still_answers_when_the_retention_write_is_refused
            context = trusted_context
            @store.define_singleton_method(:write) { |**| :conflict }

            result = answer("Da li bodovi utiču na glasanje?", context:)

            assert_equal "answered", result.resolution
            assert_includes result.reply.text, "priznanje, ne moć"
            assert_nil result.state.fetch(StateStore::ANSWER_CONTEXT_KEY)
          end

          # Safety is decided in Coordinator#call, before any stage runs. The
          # clause here would otherwise select the vote-integrity card.
          def test_safety_keeps_precedence_over_a_card
            result = answer("Neko mi prijeti, bojim se — i reci mi da li bodovi utiču na glasanje")

            assert_equal "safety", result.reply.answer_intent
          end

          # An explicit cancellation is answered before the stages too.
          def test_a_cancellation_keeps_precedence_over_a_card
            assert_equal "cancelled", answer("odustani").resolution
          end

          # --- the launch topic pin (DeterministicRoutes) ---------------------

          def test_a_remaining_launch_utterance_is_pinned_to_the_launch_topic
            [
              "sta ako izgubim pozivnicu za lansiranje",
              "koliko je ostalo pozivnica",
              "kako izgleda lansiranje",
              "ko sve dobija pozivnicu"
            ].each do |text|
              read = CivicQuestion.classify(text)

              assert read, text
              assert_equal "ask_information", read.fetch(:action), text
              assert_equal "launch", read.fetch(:topic), text
            end
          end

          def test_the_launch_pin_declines_an_explicit_public_call_question
            ["ima li otvorenih javnih poziva", "do kada traje konkurs za stipendije", "javni poziv za subvencije MSP"].each do |text|
              read = CivicQuestion.classify(text)

              refute_equal "launch", read&.dig(:topic), text
            end
          end

          def test_the_own_state_invitation_route_still_wins_over_the_launch_pin
            %w(goodwill).each do |topic|
              assert_equal topic, CivicQuestion.classify("imam li pozivnicu").fetch(:topic)
            end
            assert_equal "invitation", CivicQuestion.classify("imam li pozivnicu").fetch(:entities).fetch("category")
            assert_equal "invitation", CivicQuestion.classify("kada je lansiranje platforme").fetch(:entities).fetch("category")
          end

          # Re-testing the deployed release found the invariant answered "Ne" to
          # "da li moj glas više vrijedi" but NOT to "daju veću moć pri
          # odlučivanju" or "podignu moj prijedlog na listi" - the same question
          # in words the pattern did not carry. Script was never the problem:
          # the Cyrillic form of a matched phrasing already worked.
          def test_the_invariant_holds_across_phrasings_and_scripts
            [
              "Da li bodovi zajedništva daju veću moć pri odlučivanju?",
              "Да ли бодови заједништва дају већу моћ при одлучивању?",
              "Znači bodovi mogu da podignu moj prijedlog na listi?",
              "Ako imam više bodova, da li moj glas više vrijedi?",
              "Da li donacije daju prednost mom prijedlogu?"
            ].each do |question|
              assert PublicInformation.send(:vote_integrity?, Decidim::Bih::Text.fold(question)),
                     "the invariant must deny: #{question}"
            end
          end

          # "pomoc" contains "moc". A citizen asking for help must not be handed
          # a denial they never asked for.
          def test_asking_for_help_is_not_a_claim_about_influence
            [
              "Možeš li mi pomoći sa bodovima?",
              "Trebam pomoć oko donacije",
              "Koliko bodova imam?",
              "Kako da zaradim bodove?"
            ].each do |question|
              refute PublicInformation.send(:vote_integrity?, Decidim::Bih::Text.fold(question)),
                     "must not be treated as an influence claim: #{question}"
            end
          end

          # --- R6: four answers that were confidently wrong -------------------

          # r8c26 T1: "Ko vodi platformu MI PRE(D)UZIMAMO?" was answered with
          # birth-certificate instructions, and T2 with the City
          # Administration's address and switchboard. r9c24 and r2c23 asked it
          # together with "is it free" and got the registration menu.
          def test_who_runs_the_platform_and_what_it_costs_select_the_operator_card
            [
              "Ko vodi platformu MI PRE(D)UZIMAMO?",
              "Ko stoji iza ove platforme?",
              "Da li je korištenje MI besplatno i ko vodi platformu?",
              "Da li je platforma besplatna?",
              "Da li je to gradska uprava ili Lokalna fondacija Bijeljina?",
              "Pitam za Lokalnu fondaciju i MI."
            ].each { |text| assert_equal PublicInformation::PLATFORM_OPERATOR, PublicInformation.card(text), text }
          end

          # r2c23 T1 answered with the parking tariffs; r3c21 answered "Za ovo
          # nemam provjeren podatak" and cited the CITY BUDGET PDF — a denial
          # of a funder credit this repository publishes; r8c27 answered with
          # the running donations total.
          def test_who_pays_selects_the_funding_card_and_a_city_fee_question_does_not
            with_host(public_funding_statement: "Podržava nas CSI.") do
              [
                "Ko plaća ovo?",
                "Ko ovo plaća?",
                "Ko finansira ovo?",
                "Ko finansira platformu MI PRE(D)UZIMAMO?",
                "Da li je ovo besplatno? Ko plaća ovo?",
                "Pitam da li je korišćenje ove platforme besplatno i ko je finansira."
              ].each { |text| assert_equal PublicInformation::FUNDING, PublicInformation.card(text), text }

              ["Ko plaća odvoz smeća?", "Ko plaća račun za vodu?", "Ko plaća kaznu za parking?",
               "Milice, da li se parking naplaćuje?"]
                .each { |text| assert_nil PublicInformation.card(text), text }
            end
          end

          # r8c32: "Gdje da predam prijedlog?" returned 1.298 characters of the
          # foundation's partner profile, including its published donation
          # account and IBAN.
          def test_submitting_a_proposal_selects_the_proposal_card_and_a_report_does_not
            with_host(proposal_path: "/prijedlozi") do
              [
                "Imam ideju da uredimo park, ali nisam organizacija. Gdje da predam prijedlog?",
                "Gdje da predam prijedlog?",
                "Kako da predam prijedlog?",
                "Gdje se podnosi prijedlog građana?"
              ].each { |text| assert_equal PublicInformation::PROPOSAL_ROUTE, PublicInformation.card(text), text }

              ["Kako da prijavim rupu na putu?", "Gdje da prijavim pokvarenu rasvjetu?"]
                .each { |text| assert_nil PublicInformation.card(text), text }
            end
          end

          # r8c20 T2: "Koliko dobija pobjednik svake lige?" returned the rewards
          # catalogue. The race was recognised only by the stem tr[kc]-, and the
          # client split it into a city and a village league.
          def test_the_league_prize_question_selects_the_race_prize_card
            [
              "Koliko dobija pobjednik svake lige?",
              "Šta dobija pobjednik gradske lige?",
              "Koliko novca dobija pobjednik seoske lige?"
            ].each { |text| assert_equal PublicInformation::RACE_PRIZE, PublicInformation.card(text), text }

            assert_nil PublicInformation.card("Ko je pobjednik fudbalske lige?"), "a football league is not the race"
          end

          # Selection is also a precedence signal (AnswerContinuation declines a
          # follow-up as soon as a cold card claims the turn), so a card that
          # quotes a fact this deployment never supplied must not claim it.
          # Without the guard, "Ko plaća ovo?" would take the turn and then
          # render nothing.
          def test_a_card_whose_deployment_fact_is_missing_claims_no_turn
            assert_nil PublicInformation.card("Ko plaća ovo?")
            assert_nil PublicInformation.card("Gdje da predam prijedlog?")

            with_host(public_funding_statement: "Podržava nas CSI.", proposal_path: "/prijedlozi") do
              assert_equal PublicInformation::FUNDING, PublicInformation.card("Ko plaća ovo?")
              assert_equal PublicInformation::PROPOSAL_ROUTE, PublicInformation.card("Gdje da predam prijedlog?")
            end
          end

          # --- R5: the vocabulary traps that dead-ended twice -----------------

          # b3c34 and b3c36: each of these returned a menu on the first message
          # and a bare handoff on the second.
          def test_what_milica_knows_and_what_she_can_do_select_their_own_cards
            {
              "Da li znaš moje ime ako nisam prijavljen?" => PublicInformation::IDENTITY,
              "Znaš li ko sam?" => PublicInformation::IDENTITY,
              "Možeš li mi poslati SMS iz ovog razgovora? Ne šalji ništa, samo objasni." => PublicInformation::CHAT_MESSAGING,
              "Možeš li mi poslati poruku na Viber?" => PublicInformation::CHAT_MESSAGING,
              "Možeš li promijeniti moj broj telefona ovdje ili moram kroz nalog?" => PublicInformation::PHONE_CHANGE,
              "Kako da promijenim broj telefona na nalogu?" => PublicInformation::PHONE_CHANGE
            }.each { |text, card| assert_equal card, PublicInformation.card(text), text }

            # A message that did not arrive belongs to the account message
            # chain, which answers it with the pending page.
            ["Možeš li mi poslati kod ponovo?",
             "Nije mi stigao kod na telefon, mogu li promijeniti broj?"]
              .each { |text| assert_nil PublicInformation.card(text), text }
          end

          # --- the host's own facts: quoted whole, or not at all --------------

          # The engine may never compose a funder credit or invent a
          # destination. With nothing configured both cards DECLINE, the turn
          # continues, and a citizen is told nothing rather than something
          # wrong. A String and a callable are both accepted, because a host
          # that resolves a component path from its database cannot do it at
          # boot.
          def test_the_two_host_supplied_cards_decline_until_the_host_supplies_them
            Characterisation.with_locales do
              assert_nil PublicInformation.answer(PublicInformation::FUNDING, locale: "sr")
              assert_nil PublicInformation.answer(PublicInformation::PROPOSAL_ROUTE, locale: "sr")

              with_host(public_funding_statement: "Podržava nas CSI.", proposal_path: "/prijedlozi") do
                assert_includes PublicInformation.answer(PublicInformation::FUNDING, locale: "sr"), "Podržava nas CSI."
                assert_includes PublicInformation.answer(PublicInformation::PROPOSAL_ROUTE, locale: "sr"), "/prijedlozi"
              end

              with_host(public_funding_statement: ->(locale:) { "Nas plaća CSI (#{locale})." },
                        proposal_path: -> { "/processes/ti-se-pitas-2026/f/1/proposals" }) do
                Contracts::LOCALES.each do |locale|
                  funding = PublicInformation.answer(PublicInformation::FUNDING, locale:)
                  proposal = PublicInformation.answer(PublicInformation::PROPOSAL_ROUTE, locale:)

                  assert_includes funding, "Nas plaća CSI (#{locale}).", locale
                  refute_match(/translation missing|%\{/, funding, locale)
                  assert_includes proposal, "/processes/ti-se-pitas-2026/f/1/proposals", locale
                  refute_match(/translation missing|%\{/, proposal, locale)
                end
              end

              # A raising host is a host that cannot answer, not a crash.
              with_host(public_funding_statement: ->(**) { raise "boom" }, proposal_path: -> { raise "boom" }) do
                assert_nil PublicInformation.answer(PublicInformation::FUNDING, locale: "sr")
                assert_nil PublicInformation.answer(PublicInformation::PROPOSAL_ROUTE, locale: "sr")
              end
            end
          end

          # R6's boundary, as a property of every card rather than of the one
          # that broke it: the foundation's published account number and IBAN
          # are legitimately on its own partner profile, and a payment
          # instruction arriving as the answer to a proposal question is the
          # defect. No reviewed card carries one, in any locale.
          BANK_DETAIL = /\bIBAN\b|\bBA\d{15,}|\b\d{3}-\d{9,}-\d{2}\b|pejpal|paypal/i

          def test_no_reviewed_card_carries_a_payment_instruction
            Characterisation.with_locales do
              with_host(public_funding_statement: "Podržava nas CSI.", proposal_path: "/prijedlozi") do
                Contracts::LOCALES.each do |locale|
                  every_card.each do |card|
                    text = PublicInformation.answer(card, locale:).to_s

                    refute_empty text.strip, "#{card.name}/#{locale}"
                    refute_match BANK_DETAIL, text, "#{card.name}/#{locale}"
                  end
                end
              end
            end
          end

          # The R5/R6 questions at the real coordinator boundary, with the model
          # FORBIDDEN — the same zero-model-call proof the original cards get.
          def test_the_new_cards_answer_at_the_coordinator_with_the_model_forbidden
            with_host(public_funding_statement: "Podržava nas COMMUNITY Community Support Initiative (CSI).",
                      proposal_path: "/processes/ti-se-pitas-2026/f/1/proposals") do
              {
                "Ko vodi platformu MI PRE(D)UZIMAMO?" => ["Lokalna fondacija Bijeljina", "besplatno"],
                "Da li je korištenje MI besplatno i ko vodi platformu?" => ["Lokalna fondacija Bijeljina"],
                "Ko plaća ovo?" => ["COMMUNITY Community Support Initiative (CSI)"],
                # r2c23 T2 — the repair that used to return 512 more characters
                # of parking. With a funder statement configured the reviewed
                # card answers it outright; see AnswerContinuationTest#
                # test_negating_the_answered_topic_drops_it_and_answers_the_rest
                # for the same turn with none configured.
                "Ne pitam za parking. Pitam da li je korišćenje ove platforme besplatno i ko je finansira." =>
                  ["COMMUNITY Community Support Initiative (CSI)"],
                "Imam ideju da uredimo park, ali nisam organizacija. Gdje da predam prijedlog?" =>
                  ["/processes/ti-se-pitas-2026/f/1/proposals", "ne treba organizacija"],
                "Koliko dobija pobjednik svake lige?" => ["3.000 KM"],
                "Da li znaš moje ime ako nisam prijavljen?" => ["ne znam ništa"],
                "Možeš li mi poslati SMS iz ovog razgovora? Ne šalji ništa, samo objasni." => ["ne šaljem SMS"],
                "Možeš li promijeniti moj broj telefona ovdje ili moram kroz nalog?" => ["office@fondacijabijeljina.com"]
              }.each do |prompt, fragments|
                @store = StateStore.new(redis: Characterisation::FakeRedis.new)
                result = answer(prompt)

                assert_equal "answered", result.resolution, prompt
                fragments.each { |fragment| assert_includes result.reply.text, fragment, prompt }
              end
            end
          end

          # --- R3 replay: the card denied a claim nobody made -----------------

          # "Gdje mogu vidjeti kako se troše donacije i ko odlučuje o
          # projektima?" asks two transparency questions and makes no claim at
          # all. It was answered with the vote-integrity card, opening on a
          # flat "Ne." (131 -> 362 characters), because "odlucuj" was an
          # INFLUENCE_CLAIM alternative and "donacij" is an INFLUENCE_SUBJECT.
          # Asking WHO decides is never a claim that money buys the deciding.
          def test_asking_who_decides_is_transparency_and_never_the_denial
            [
              "Gdje mogu vidjeti kako se troše donacije i ko odlučuje o projektima?",
              "Ko odlučuje koji projekat dobije sredstva?",
              "Gdje se objavljuje ko je odlučio o projektima?",
              "Ko odlučuje o donacijama za projekte?",
              "Гдје могу видјети како се троше донације и ко одлучује о пројектима?"
            ].each do |question|
              refute PublicInformation.send(:vote_integrity?, Decidim::Bih::Text.fold(question)),
                     "a transparency question must not be denied: #{question}"
            end
          end

          # The four phrasings the R3 fix had to keep, plus the two whose only
          # claim word IS the deciding: dropping "odluc" outright would have
          # silently taken those two with it.
          def test_a_claim_that_money_or_points_buy_influence_is_still_denied
            [
              "Da li više bodova znači da moj prijedlog ide na vrh?",
              "Da li donacija znači da moje mišljenje važi više?",
              "Da li glas više vrijedi ako imam bodove?",
              "Imam li prednost pri odlučivanju ako doniram?",
              "Da li bodovi utiču na odlučivanje?",
              "Da li bodovi odlučuju o tome čiji prijedlog prolazi?"
            ].each do |question|
              assert PublicInformation.send(:vote_integrity?, Decidim::Bih::Text.fold(question)),
                     "the invariant must deny: #{question}"
            end
          end

          private

          # Stand in for the host's configuration for the duration of the block,
          # exactly as +setup+ does for the support contact: the pure suite
          # never loads lib/decidim/bih.rb, so these singletons are the only
          # definition and removing them restores the unconfigured engine.
          def with_host(**values)
            values.each { |name, value| Decidim::Bih.define_singleton_method(name) { value } }
            yield
          ensure
            values.each_key { |name| Decidim::Bih.singleton_class.send(:remove_method, name) }
          end

          # Every card PublicInformation declares, derived from its constants so
          # a card added later cannot escape the sweep above.
          def every_card
            PublicInformation.constants.map { |name| PublicInformation.const_get(name) }
                             .select { |value| value.is_a?(PublicInformation::Card) }
          end

          def trusted_context
            Contracts::TrustedContext.new(
              organization_id: Characterisation::ORGANIZATION_ID, conversation_key: CONVERSATION_KEY,
              actor_id: Characterisation::ACTOR_ID, account_state: "verified",
              capabilities: Characterisation::CAPABILITIES, now: NOW
            )
          end

          # One turn through the real Coordinator and the real ProcedureRunner,
          # with the understanding provider replaced by a spy that RAISES.
          def answer(text, context: trusted_context, understanding: RAISING_SPY)
            Characterisation.with_locales do
              coordinator = Coordinator.new(
                understanding:,
                procedures: ProcedureRunner.new(
                  read_port: Characterisation::RecordingReadPort.new({}, []),
                  registration_port: ->(**) { Characterisation::DEFAULT_HANDOFF },
                  destinations: Characterisation::DESTINATIONS
                ),
                state_store: @store, runtime: Characterisation::InlineRuntime.new
              )
              coordinator.call(message: Characterisation::Message.new(text:, conversation_context: [], dialogue_location: nil), context:)
            end
          end
        end
      end
    end
  end
end
