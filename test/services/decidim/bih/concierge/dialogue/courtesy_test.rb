# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/courtesy"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class CourtesyTest < Minitest::Test
          def test_closure_is_a_courtesy_without_swallowing_a_new_request
            ["Hvala, dovoljno je.", "Хвала, довољно је."].each do |text|
              assert_equal "thanks", Courtesy.kind(text)
            end
            assert_nil Courtesy.kind("Hvala, dovoljno je. Kako da obrišem nalog?")
          end

          def test_greetings_in_every_script
            ["zdravo", "Zdravo!", "ćao", "cao", "pozdrav", "hej", "здраво", "hello", "hi", "dobar dan", "Dobro jutro", "Ćao Milice"].each do |text|
              assert_equal "greeting", Courtesy.kind(text), text
            end
          end

          def test_thanks_in_every_script_and_with_filler
            ["hvala", "Hvala ti puno!", "e hvala ti puno", "hvala lijepo", "fala", "хвала", "Хвала ти", "thanks", "thank you", "hvala Milice"].each do |text|
              assert_equal "thanks", Courtesy.kind(text), text
            end
          end

          def test_farewells
            ["doviđenja", "dovidjenja", "ćao ćao", "pozdrav i hvala", "hvala i pozdrav", "bye", "zbogom", "довиђења"].each do |text|
              assert_equal "farewell", Courtesy.kind(text), text
            end
          end

          def test_capabilities_including_the_legacy_help_phrases
            ["sta sve znas?", "Šta možeš?", "šta umiješ", "kako mi mozes pomoci", "kako mi možeš pomoći?", "what can you do", "pomozi mi",
             "treba mi pomoc", "reci mi šta sve znaš", "шта све знаш"].each do |text|
              assert_equal "capabilities", Courtesy.kind(text), text
            end
            Responder::HELP_PHRASES.each { |phrase| assert_equal "capabilities", Courtesy.kind(phrase), phrase }
          end

          def test_questions_commands_and_long_text_are_not_courtesy
            ["hvala, a kad se odvozi smeće", "zdravo, koliko košta parking", "ne", "da", "odustani", "nastavi", "", "   ",
             "hvala #{"puno " * 20}", "kad se odvozi smeće", "pomoc", "help"].each do |text|
              assert_nil Courtesy.kind(text), text.inspect
            end
            assert_nil Courtesy.kind(nil)
            assert_nil Courtesy.kind(42)
          end
        end
      end
    end
  end
end
