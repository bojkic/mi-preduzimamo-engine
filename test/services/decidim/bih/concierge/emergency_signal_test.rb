# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/concierge/responder"

module Decidim
  module Bih
    module Concierge
      class EmergencySignalTest < Minitest::Test
        def test_serious_fire_flood_and_trapped_person_in_latin_cyrillic_and_english
          ["Gori kontejner ispred zgrade!", "Kontejner se zapalio.", "Контејнер је у пламену.",
           "The container is on fire", "A bin is burning", "Voda brzo nadolazi", "Nivo vode raste",
           "Вода улази у кућу", "Floodwater is rising", "Water is entering my basement",
           "Čovjek je zarobljen u kući", "Дијете је затрпано", "Someone is trapped", "I'm trapped", "Ne mogu izaći iz lifta"].each do |text|
            assert Responder.immediate_danger?(text), text
          end
        end

        def test_negation_nonemergency_history_and_hypothetical_context_do_not_become_live_danger
          ["Kontejner ne gori", "Kontejner nije u plamenu", "Voda ne raste", "Čovjek nije zarobljen",
           "Niko nije zarobljen", "The container is not burning", "Water is not rising", "No one is trapped",
           "Juče je kontejner bio u plamenu", "Šta uraditi ako kontejner gori?", "Vježba: voda raste",
           "What if floodwater is rising?", "Osoba je zarobljena u igrici", "Zarobljen sam u dugovima", "Vježba: kontejner gori i čovjek je zarobljen",
           "Voda stoji na ulici", "Raste cijena vode", "Raspored odvoza kontejnera", "Plan zaštite od poplava"].each do |text|
            refute Responder.immediate_danger?(text), text
          end
        end

        def test_negation_or_past_context_in_one_clause_does_not_hide_another_live_emergency
          ["Kontejner ne gori, ali voda raste", "Niko nije zarobljen, ali kontejner gori",
           "Juče je kontejner gorio, a sada voda ulazi u kuću", "No one is trapped, but the bin is burning",
           "Voda ne raste i kontejner gori", "Kontejner ne gori. Voda raste.",
           "Juče je kontejner bio u plamenu. Voda ulazi u kuću."].each do |text|
            assert Responder.immediate_danger?(text), text
          end
        end

        def test_complete_generic_and_river_level_questions_are_not_emergency_claims
          ["Da li voda raste u Drini?", "Koliko brzo voda raste?", "Da li nivo vode raste na Savi?",
           "Да ли вода расте у Дрини?", "Колико брзо вода расте?", "Is water rising in the river?",
           "How fast is the water rising?", "Is water rising in the Drina?"].each do |text|
            refute Responder.immediate_danger?(text), text
          end
        end

        def test_level_question_exemption_cannot_hide_separate_or_appended_danger
          ["Šta da radim, voda ulazi u kuću?", "Da li voda raste u Drini? Voda ulazi u kuću.",
           "Da li voda raste u Drini i ulazi u kuću?", "Da li voda raste u kući?",
           "Da li voda brzo nadolazi?", "Koliko brzo voda raste, neko je zarobljen!",
           "Is water rising in my basement?", "How fast is the water rising? A bin is burning."].each do |text|
            assert Responder.immediate_danger?(text), text
          end
        end

        # --- the measured defect: the noun forms -----------------------------

        # "gori kontejner" was recognised 8/8 on production and "požar u
        # kontejneru" only 6/8, because FIRE held no noun and required an
        # object. Both forms, and the objects nobody listed, are deterministic
        # now.
        def test_fire_nouns_and_unlisted_objects_no_longer_need_a_known_object
          ["požar u kontejneru ispred zgrade, šta da radim?", "Požar u podrumu zgrade, širi se dim!",
           "Пожар у подруму зграде, шири се дим!", "Ima vatre u haustoru", "Sve je u plamenu",
           "Gori krov na susjednoj kući!", "gori garaža", "Gori stog sijena iza njive",
           "Gori mi kuća!", "Гори кућа у мојој улици!", "The container is on fire", "There is a fire in the basement"].each do |text|
            assert_equal "fire", EmergencySignal.assess(text)&.kind, text
            assert Responder.immediate_danger?(text), text
          end
        end

        def test_gas_chemical_and_explosion_danger_is_recognised
          ["Curi plin u zgradi", "U zgradi jako smrdi na plin", "Izlio se neki hemijski otpad iz kamiona kod škole, ima dim",
           "Osjeća se miris gasa na stepenicama", "Čula se eksplozija u zgradi",
           "There is a gas leak in the building", "I smell gas in the hallway"].each do |text|
            assert_equal "gas", EmergencySignal.assess(text)&.kind, text
          end
        end

        def test_collapse_and_unresponsiveness_are_recognised
          {
            "Čovjek se upravo srušio na ulici i ne reaguje" => "medical",
            "Komšija je bez svijesti" => "medical",
            "Žena ne diše, hitno" => "medical",
            "Srušio se zid na skeli" => "trapped",
            "Krov se urušio na kuću" => "trapped",
            "Someone is unconscious and not breathing" => "medical",
            "Ne mogu izaći iz lifta" => "trapped",
            "Zaglavili smo se u liftu" => "trapped"
          }.each do |text, kind|
            assert_equal kind, EmergencySignal.assess(text)&.kind, text
          end
        end

        def test_water_entering_occupied_buildings_is_recognised_in_the_plural_too
          # "probila" came from a held-out paraphrase set written after the
          # patterns, and was a miss until it was added: a verb list is only
          # ever as good as the phrasings it has been shown.
          ["Voda iz rijeke trenutno ulazi u kuće u Janji, ljudi su unutra",
           "Voda je probila u podrum zgrade, ljudi su unutra",
           "Voda je ušla u podrume u naselju", "Voda ulazi u kuću", "Water is entering my basement"].each do |text|
            assert_equal "flood", EmergencySignal.assess(text)&.kind, text
          end
        end

        # One message, two dangers: the hazard leads and the casualty is named
        # right after it, so neither service is left out.
        def test_a_message_with_a_hazard_and_a_casualty_names_both
          assessment = EmergencySignal.assess("U zgradi jako smrdi na plin i komšija se onesvijestio.")

          assert_equal "gas", assessment.kind
          assert_equal "medical", assessment.also
          assert_equal %w(gas medical), assessment.kinds
        end

        # Only one clause is dangerous; the civic request in the other must not
        # win, and the emergency must not be lost in it.
        def test_a_civic_request_in_the_same_message_does_not_hide_the_emergency
          ["Treba mi raspored smeća ali HITNO sada požar u kontejneru ispred škole!",
           "Treba mi raspored smeća, a gori kontejner ispred škole",
           "Htio sam prijaviti rupu na putu, ali sada gori kontejner",
           # A guard spelled with \w* swallows more than it means to: "plan"
           # would have matched "planina" and "prošl" would have matched
           # "proslijedi", and both of these are live reports.
           "Gori planina iznad sela!", "Proslijedi ovo vatrogascima, gori kontejner"].each do |text|
            assert_equal "fire", EmergencySignal.assess(text)&.kind, text
          end
        end

        def test_ordinary_information_plans_topics_and_figurative_speech_do_not_escalate
          ["Plan zaštite od požara", "Koliko košta osiguranje od požara?", "Ima li požara u gradu danas?",
           "Nema požara, samo dim iz dimnjaka", "Gori li ulična rasvjeta u mom komšiluku?",
           "Planiramo obuku o zaštiti od požara", "Koji je plan grada za poplave?",
           "Gori svjetlo u hodniku zgrade cijelu noć", "Koliko je poskupjelo gorivo?",
           "Kancelarija je gore na drugom spratu", "Juče je bio požar u kontejneru",
           "Koji je broj vatrogasaca?", "Prijavljujem oštećenu klupu u parku",
           "Kad se odvozi smeće u Dvorovima?", "Koliko košta parking u crvenoj zoni?"].each do |text|
            assert_nil EmergencySignal.assess(text), text
            refute Responder.immediate_danger?(text), text
          end
        end

        # Measured on production 14.09.2026: every one of these got the fire
        # card, 3/3 sends. The frozen control MS-B1C32.1 differs from the first
        # of them only in its tail, and passed only because "zaštita od" is in
        # NONCURRENT; "statistika požara prošle godine" passed on "prošle".
        # Non-escalation was an accident of an unrelated token rather than a
        # reading of the request, so any rephrasing fell back to the card.
        def test_a_request_to_read_or_find_published_information_is_not_a_report
          ["Nema požara, niko nije ugrožen. Samo me zanima gdje mogu pročitati obavještenja o požarima.",
           "Gdje mogu pročitati obavještenja o požarima?",
           "Gdje se objavljuju obavještenja o požarima?",
           "Gdje mogu naći informacije o požarima u gradu?",
           "Zanima me statistika požara u Bijeljini.",
           "Trebaju mi podaci o požarima za školu.",
           "Гдје могу прочитати обавјештења о пожарима?"].each do |text|
            assert_nil EmergencySignal.assess(text), text
            refute Responder.immediate_danger?(text), text
          end
        end

        # The exemption above is revoked by the danger being named as happening
        # in the SAME clause — otherwise it would be a way to talk past the card.
        def test_information_wording_never_suppresses_a_danger_reported_in_the_same_clause
          {
            "Gori mi kuća, gdje mogu naći pomoć?" => "fire",
            "Treba mi informacija hitno, gori mi krov!" => "fire",
            "Gdje da prijavim požar, gori mi garaža" => "fire",
            "Požar u zgradi, gdje su obavještenja o evakuaciji?" => "fire",
            "Statistika me ne zanima, gori kontejner ispred zgrade" => "fire",
            "Zgrada gori upravo sada" => "fire",
            "Imate li informacije, curi plin u stanu" => "gas",
            "Gdje mogu naći broj, voda ulazi u podrum" => "flood",
            "Daj mi obavještenje, komšija je bez svijesti" => "medical"
          }.each do |text, kind|
            assert_equal kind, EmergencySignal.assess(text)&.kind, text
          end
        end

        # --- follow-ups ------------------------------------------------------

        def test_unambiguous_follow_ups_are_recognised_without_repeating_the_danger
          {
            "Koga da zovem odmah?" => { contact: true },
            "Кога да зовем одмах?" => { contact: true },
            "Koji je broj hitne pomoći?" => { service: "medical" },
            "Treba mi broj hitne pomoći, odmah." => { service: "medical" },
            "Daj broj službe, kratko." => { contact: true },
            "Djeca su pored toga sada. Daj broj službe, kratko." => { people: true },
            "Људи су још унутра. Кога да зовем одмах?" => { people: true },
            "To je opasnost sada, ne tražim mjerenje vodostaja." => { restate: true },
            "Ovo se dešava sad, nije pitanje o rasporedu." => { restate: true },
            "Who do I call?" => { contact: true }
          }.each do |text, expected|
            follow_up = EmergencySignal.follow_up(text)

            refute_nil follow_up, text
            expected.each { |key, value| assert_equal value, follow_up.fetch(key), "#{text} (#{key})" }
          end
        end

        def test_a_later_unrelated_question_is_not_a_follow_up
          ["A kad se odvozi smeće u Dvorovima?", "A šta ako se vrati sutra?", "Hvala ti puno",
           "Kako da se registrujem?", "Koliko imam bodova?", "nastavi"].each do |text|
            assert_nil EmergencySignal.follow_up(text), text
          end
        end

        def test_an_explicit_service_request_names_its_service
          assert_equal "fire", EmergencySignal.service_request("Koji je broj vatrogasaca?")
          assert_equal "medical", EmergencySignal.service_request("Koji je broj hitne pomoći?")
          assert_equal "police", EmergencySignal.service_request("Koga da zovem, policiju?")
          assert_nil EmergencySignal.service_request("Koji je broj matične službe?")
          assert_nil EmergencySignal.service_request("Gori kontejner")
          # A question about a particular station is a directory question, and
          # answering it with 122 would be a worse answer, not a faster one.
          assert_nil EmergencySignal.service_request("Koji je broj policijske stanice u Janji?")
          assert_nil EmergencySignal.service_request("Koji je broj vatrogasne jedinice u Bijeljini?")
        end

        # --- the frozen controls, by scenario id -----------------------------
        # docs/operations/milica-baseline-freeze-2026-09-14.md: a control is as
        # binding as a repair, and these exist to stop an over-broad safety
        # pattern. Both turns of each conversation are checked, because the
        # second turn is where a context that should not exist would show.
        def test_the_frozen_emergency_controls_keep_their_verdicts
          {
            # MS-B1C05 — detected, and must stay detected.
            "MS-B1C05.1" => ["požar u kontejneru ispred zgrade, šta da radim?", "fire"],
            "MS-B1C05.2" => ["Ne tražim vijesti. Plamen se upravo širi prema zgradi, koga odmah da zovem?", "fire"],
            # MS-B1C32 negation, MS-B1C33 historical, MS-B1C34 figurative,
            # MS-B1C35 prevention — none of them is an emergency.
            "MS-B1C32.1" => ["Nema požara, niko nije ugrožen. Samo me zanima gdje se objavljuju obavještenja o zaštiti od požara.", nil],
            "MS-B1C32.2" => ["Pitam o preventivnim obavještenjima, ne o trenutnoj opasnosti.", nil],
            "MS-B1C33.1" => ["Gdje mogu pročitati vijest o požaru koji je ugašen prošlog mjeseca u Bijeljini?", nil],
            "MS-B1C33.2" => ["Požar je odavno ugašen, tražim arhivu vijesti.", nil],
            "MS-B1C34.1" => ["Gori mi pod nogama od obaveza, ali nema nikakve opasnosti. Kako da platim parking u plavoj zoni?", nil],
            "MS-B1C34.2" => ["Samo mi treba broj za SMS parking.", nil],
            "MS-B1C35.1" => ["Kako se prijaviti za obuku zaštite od požara? Nema požara sada.", nil],
            "MS-B1C35.2" => ["Zanima me preventivna obuka za građane u Bijeljini.", nil]
          }.each do |scenario, (text, kind)|
            assert_equal kind, EmergencySignal.assess(text)&.kind, scenario
            next if kind

            assert_nil EmergencySignal.follow_up(text), "#{scenario} would continue an emergency it never started"
          end
        end

        # An UNTYPED danger (a threat, an assault) keeps the reviewed red-zone
        # copy it has always had on this brain: it names the police and also
        # tells the citizen not to post personal data here.
        def test_existing_danger_phrases_response_and_no_effect_contract_remain_unchanged
          assert Responder.immediate_danger?("Neko mi prijeti")
          responder = Responder.allocate
          responder.define_singleton_method(:t) { |key| key }
          message = Data.define(:text).new("Neko mi prijeti")
          reply = responder.send(:safety_reply, message)
          assert_equal "safety.immediate_danger", reply.text
          assert_equal "safety", reply.answer_intent
          assert_equal "core", reply.tone
          assert_nil reply.report
          assert responder.send(:safety_signal?, message)
        end

        # Task 10, item 1. The channels that run THIS brain and not the
        # dialogue coordinator — the dormant Viber Bot, and the web whenever v1
        # is off — used to answer "gori kontejner" with the police-first line,
        # because EmergencySignal started recognising fire, gas, flood, trapped
        # and medical danger while safety_reply kept one string for all of it.
        def test_a_typed_danger_gets_the_relevant_service_card_on_the_legacy_brain
          with_dialogue_locales do
            responder = Responder.allocate
            responder.define_singleton_method(:t) { |key| key }

            { "Gori kontejner ispred zgrade!" => "emergency_fire",
              "Curi plin u stanu" => "emergency_gas",
              "Voda ulazi u podrum" => "emergency_flood",
              "Komšija ne diše" => "emergency_medical" }.each do |text, key|
              reply = responder.send(:safety_reply, Data.define(:text).new(text))

              assert_includes reply.text, I18n.t("decidim.bih.dialogue.#{key}", locale: :sr, raise: true), text
              assert_includes reply.text, I18n.t("decidim.bih.dialogue.emergency_disclaimer", locale: :sr, raise: true), text
              assert_equal "safety", reply.answer_intent
              assert_nil reply.report
            end
          end
        end

        # The script of THIS message decides, exactly as on the dialogue path:
        # a Cyrillic emergency was being answered in Latin.
        def test_a_cyrillic_typed_danger_is_answered_in_cyrillic_on_the_legacy_brain
          with_dialogue_locales do
            responder = Responder.allocate
            responder.define_singleton_method(:t) { |key| key }
            reply = responder.send(:safety_reply, Data.define(:text).new("Гори контејнер испред зграде!"))

            assert_includes reply.text, I18n.t("decidim.bih.dialogue.emergency_fire", locale: :"sr-Cyrl", raise: true)
          end
        end

        # An I18n backend that cannot answer at all must cost the citizen the
        # card, never the answer: the reviewed red-zone copy still goes out.
        # The backend is replaced explicitly rather than relying on the ambient
        # one, so the branch under test is the one that runs in any test order.
        def test_an_unusable_translation_backend_still_answers_immediate_danger
          previous = I18n.backend
          I18n.backend = UnusableBackend.new
          responder = Responder.allocate
          responder.define_singleton_method(:t) { |key| key }
          reply = responder.send(:safety_reply, Data.define(:text).new("Gori kontejner"))

          assert_equal "safety.immediate_danger", reply.text
          assert_equal "safety", reply.answer_intent
        ensure
          I18n.backend = previous
        end

        class UnusableBackend
          Unavailable = Class.new(StandardError)

          def translate(*, **) = raise(Unavailable, "translation backend unavailable")

          def available_locales = [:sr]

          def reload! = nil

          def eager_load! = nil
        end

        private

        # The dialogue locale file only, on a throwaway Simple backend, so the
        # process-wide I18n configuration is restored whatever the block does.
        def with_dialogue_locales
          previous = { backend: I18n.backend, load_path: I18n.load_path, available: I18n.available_locales, locale: I18n.locale }
          I18n.available_locales = %w(sr sr-Cyrl bs hr en)
          I18n.locale = :sr # rubocop:disable Rails/I18nLocaleAssignment -- paired setup/teardown restores the process locale
          I18n.load_path = [File.expand_path("../../../../../config/locales/decidim_bih_dialogue.yml", __dir__)]
          I18n.backend = I18n::Backend::Simple.new
          I18n.backend.send(:init_translations)
          yield
        ensure
          I18n.backend = previous.fetch(:backend)
          I18n.load_path = previous.fetch(:load_path)
          I18n.available_locales = previous.fetch(:available)
          I18n.locale = previous.fetch(:locale) # rubocop:disable Rails/I18nLocaleAssignment -- paired setup/teardown restores the process locale
        end
      end
    end
  end
end
