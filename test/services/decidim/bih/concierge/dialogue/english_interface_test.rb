# frozen_string_literal: true

require "test_helper"
require "i18n"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/courtesy"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/time_text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # == The two halves of "answer this citizen in English"
        #
        # R7. Measured on production on 14.09.2026: an English question about
        # waste collection came back as
        #
        #   Da vidimo kad kese zvanično kreću na put.
        #
        #   Notices below are quoted in Serbian, exactly as the source
        #   published them.
        #
        #   Waste collection for "Patkovaca": srijeda, četvrtak. …
        #
        # Three languages in one reply, and only the middle sentence was meant
        # to be Serbian. This suite fixes the boundary between the two halves,
        # because they pull in opposite directions:
        #
        # 1. DETERMINISTIC INTERFACE AND CARD COPY — openers, courtesy cards,
        #    menus, chips, refusals, warnings, and the closed vocabularies we
        #    canonicalise source data into (a weekday). Every one of these is
        #    ours, is reviewed, and must be COMPLETE in the reply's language.
        #    Everything asserted below is in this half.
        #
        # 2. SOURCE PROSE — the text of a city notice, a source label, a URL, a
        #    quantity, a qualification, a place name. This must NOT be
        #    rewritten, which is why FactRenderer#with_source_language_note
        #    exists and stays: an English reply says once, above the facts, that
        #    they are quoted in Serbian. That behaviour is correct and is
        #    covered by SourceLanguageNoteTest; the last test here only pins
        #    the line between the two halves so a later change cannot quietly
        #    move a source quotation into half 1.
        class EnglishInterfaceTest < Minitest::Test
          LOCALE_FILE = File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__)
          Message = Data.define(:text)

          # Every alternative the courtesy matchers accept, with the language
          # it is written in. The union must still be matched exactly as
          # before: splitting the patterns into a local and an English half is
          # a refactor of WHICH language, never of WHAT counts as a courtesy.
          COURTESIES = {
            "greeting" => {
              local: ["zdravo", "cao", "ćao", "ciao", "pozdrav", "hej", "ej", "halo", "dobar dan", "dobro jutro",
                      "dobro vece", "Ćao Milice", "здраво"],
              english: ["hello", "hi", "hey", "Hello!", "hi Milice"]
            },
            "thanks" => {
              local: ["hvala", "fala", "Hvala ti puno!", "e hvala ti puno", "hvala lijepo", "ok hvala", "хвала"],
              english: ["thanks", "thank you", "thx", "thank you very much", "okay thanks that is all"]
            },
            "farewell" => {
              local: ["dovidjenja", "doviđenja", "ćao ćao", "zbogom", "prijatno", "vidimo se", "pozdrav i hvala"],
              english: ["bye", "goodbye", "bye bye"]
            },
            "capabilities" => {
              local: ["sta sve znas?", "Šta možeš?", "šta umiješ", "kako mi mozes pomoci", "pomozi mi", "treba mi pomoc"],
              english: ["what can you do", "what do you do", "how can you help", "how can you help me"]
            }
          }.freeze

          def setup
            @previous = { backend: I18n.backend, load_path: I18n.load_path, available: I18n.available_locales,
                          enforce: I18n.enforce_available_locales, locale: I18n.locale }
            I18n.enforce_available_locales = false
            I18n.backend = I18n::Backend::Simple.new
            I18n.available_locales = Contracts::LOCALES
            I18n.load_path = [LOCALE_FILE]
            I18n.backend.send(:init_translations)
            # The citizen is reading the Serbian site: that is the only locale
            # signal a control reply had before this change, and the whole
            # point is that it is the language of the PAGE, not of the person.
            I18n.locale = "sr" # rubocop:disable Rails/I18nLocaleAssignment -- paired setup/teardown restores the process locale
          end

          def teardown
            I18n.locale = @previous.fetch(:locale) # rubocop:disable Rails/I18nLocaleAssignment -- paired setup/teardown restores the process locale
            I18n.backend = @previous.fetch(:backend)
            I18n.load_path = @previous.fetch(:load_path)
            I18n.available_locales = @previous.fetch(:available)
            I18n.enforce_available_locales = @previous.fetch(:enforce)
          end

          # --- 1. the language a courtesy is written in ----------------------

          def test_splitting_the_matchers_did_not_change_what_counts_as_a_courtesy
            COURTESIES.each do |kind, halves|
              halves.values.flatten.each { |text| assert_equal kind, Courtesy.kind(text), text }
            end
            ["hvala, a kad se odvozi smeće", "zdravo, koliko košta parking", "kad se odvozi smeće", "prijavi rupu",
             "", "   ", nil, 42].each { |text| assert_nil Courtesy.kind(text), text.inspect }
          end

          def test_an_english_courtesy_names_its_language_and_a_local_one_claims_nothing
            COURTESIES.each_value do |halves|
              halves.fetch(:english).each { |text| assert_equal "en", Courtesy.locale_hint(text), text }
              halves.fetch(:local).each { |text| assert_nil Courtesy.locale_hint(text), text }
            end
          end

          def test_a_message_that_is_not_a_courtesy_never_carries_a_language_hint
            ["kad se odvozi smeće", "how much is parking in zone 1", "prijavi rupu", "", nil, 42].each do |text|
              assert_nil Courtesy.locale_hint(text), text.inspect
            end
          end

          # --- 2. the control card is answered in that language --------------

          def test_an_english_courtesy_is_answered_from_the_english_card
            { "hello" => "greeting", "thanks" => "thanks", "bye" => "farewell", "what can you do" => "capabilities" }
              .each do |text, key|
              reply = Coordinator.control_reply(message: Message.new(text:))

              assert_equal I18n.t("decidim.bih.dialogue.#{key}", locale: "en"), reply.text, text
              assert_equal "en", reply.locale, text
            end
          end

          def test_a_local_courtesy_keeps_the_language_the_citizen_is_reading_the_site_in
            { "zdravo" => "greeting", "hvala" => "thanks", "dovidjenja" => "farewell", "sta sve znas?" => "capabilities" }
              .each do |text, key|
              reply = Coordinator.control_reply(message: Message.new(text:))

              assert_equal I18n.t("decidim.bih.dialogue.#{key}", locale: "sr"), reply.text, text
              assert_equal "sr", reply.locale, text
            end
            cyrillic = Coordinator.control_reply(message: Message.new(text: "здраво"))

            assert_equal I18n.t("decidim.bih.dialogue.greeting", locale: "sr-Cyrl"), cyrillic.text
            assert_equal "sr-Cyrl", cyrillic.locale
          end

          # The bare help keyword is the other closed vocabulary on this
          # surface, and the same rule applies to it.
          def test_the_bare_help_keyword_is_answered_in_the_language_it_was_typed_in
            %w(help menu commands).each do |text|
              reply = Coordinator.control_reply(message: Message.new(text:))

              assert_equal I18n.t("decidim.bih.dialogue.clarify", locale: "en"), reply.text, text
              assert_equal "en", reply.locale, text
            end
            %w(pomoc meni komande upute).each do |text|
              reply = Coordinator.control_reply(message: Message.new(text:))

              assert_equal I18n.t("decidim.bih.dialogue.clarify", locale: "sr"), reply.text, text
              assert_equal "sr", reply.locale, text
            end
          end

          # Safety, credentials and allegations are free citizen text with no
          # closed vocabulary to read a language off. Guessing there would be a
          # guess about an emergency, so they keep the site's locale — and the
          # reply still states which language it is in, so nothing downstream
          # has to re-derive it.
          def test_a_danger_message_is_not_language_guessed_and_still_states_its_locale
            reply = Coordinator.control_reply(message: Message.new(text: "someone is threatening me"))

            assert_equal "safety", reply.answer_intent
            assert_equal "sr", reply.locale
          end

          # --- 3. the closed weekday vocabulary ------------------------------

          def test_the_canonical_collection_days_are_rendered_in_english
            assert_equal "Wednesday, Thursday", TimeText.day_names(%w(srijeda četvrtak), locale: "en")
            assert_equal "Monday, Tuesday, Friday, Saturday, Sunday",
                         TimeText.day_names(%w(ponedjeljak utorak petak subota nedjelja), locale: "en")
          end

          def test_every_other_locale_keeps_the_canonical_latin_spelling
            %w(sr bs hr sr-Cyrl).each do |locale|
              assert_equal "srijeda, četvrtak", TimeText.day_names(%w(srijeda četvrtak), locale:), locale
            end
          end

          # A vocabulary miss must never delete a day from a schedule: a
          # citizen reading one day where the programme lists two is worse than
          # a citizen reading an untranslated word.
          def test_an_unknown_day_passes_through_untouched_in_every_locale
            assert_equal "Wednesday, praznik", TimeText.day_names(%w(srijeda praznik), locale: "en")
            assert_equal "Wednesday", TimeText.day_names(["  Srijeda  "], locale: "en")
            assert_equal "", TimeText.day_names([], locale: "en")
            assert_equal "", TimeText.day_names(nil, locale: "en")
          end

          # --- 4. the language travels with a delegated read -----------------

          def test_a_delegated_read_is_told_which_language_the_turn_is_in
            responder = RecordingResponder.new
            adapter = Coordinator::LegacyReadAdapter.new(responder:)
            %w(sr sr-Cyrl bs hr en).each do |locale|
              adapter.call(message: Message.new(text: "koliki je budžet"), understanding: understanding(locale))

              assert_equal locale, responder.locales.last, locale
            end
            assert_nil Responder.established_reply_locale, "the override outlives no call"
          end

          def test_the_delegated_reply_states_the_language_it_was_written_in
            adapter = Coordinator::LegacyReadAdapter.new(responder: RecordingResponder.new)
            result = adapter.call(message: Message.new(text: "koliki je budžet"), understanding: understanding("en"))

            assert_equal "en", result.reply.locale
          end

          def test_an_unknown_established_locale_is_ignored_rather_than_half_applied
            responder = RecordingResponder.new
            Responder.with_reply_locale("de") { responder.respond(Message.new(text: "zdravo")) }

            assert_equal "sr", responder.locales.last, "script detection still decides"
          end

          def test_the_established_locale_is_restored_after_an_exception
            Responder.with_reply_locale("en") do
              assert_equal "en", Responder.established_reply_locale
              begin
                Responder.with_reply_locale("bs") { raise "boom" }
              rescue RuntimeError
                nil
              end
              assert_equal "en", Responder.established_reply_locale, "the inner scope restored the outer one"
            end
            assert_nil Responder.established_reply_locale
          end

          # --- 5. the line between interface copy and source prose -----------

          # The note above an English fact block is the CONTRACT that keeps
          # half 2 honest, so it must keep existing and keep saying Serbian.
          # Deleting it in the name of "end-to-end English" would turn every
          # quoted city notice into an unmarked mixed-language answer.
          def test_the_english_reply_can_still_say_its_facts_are_quoted_in_serbian
            note = I18n.t("decidim.bih.dialogue.facts_in_source_language", locale: "en")

            refute_empty note.to_s.strip
            assert_includes note, "Serbian"
          end

          private

          # A test double for the legacy brain that records the reply locale
          # #respond resolved, the way the real Responder resolves it.
          class RecordingResponder
            attr_reader :locales

            def initialize
              @locales = []
            end

            def respond(message)
              locale = Responder.established_reply_locale ||
                       (message.text.to_s.match?(/\p{Cyrillic}/) ? Responder::CYRILLIC_LOCALE : Responder::LOCALE)
              @locales << locale
              Responder::Reply.new(text: "budžet", report: nil, answer_intent: "budget", tone: "core")
            end
          end

          def understanding(locale)
            Contracts::Understanding.parse(
              { "action" => "ask_information", "topic" => "budget", "entities" => {}, "operation" => "start",
                "needs_clarification" => false, "secondary" => nil, "locale" => locale }
            )
          end
        end
      end
    end
  end
end
