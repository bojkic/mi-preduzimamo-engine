# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/text"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/text_predicates"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/state_store"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/public_activity_continuation"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/procedures/komsiluk"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class TextPredicatesTest < Minitest::Test
          SECRETS = [
            "123456", "+387 65 123 456", "065/123-456", "token: secret-value", "https://example.test/v/abcdefghijk",
            "Moj kod je 123456", "Код је 123456", "lozinka je tajna", "https://x.test/?code=abc", "verify_abcdefghij"
          ].freeze
          ORDINARY = [
            "2026", "2026-09-05", "1", "A sutra?", "Kako da promijenim lozinku?", "Како да промијеним лозинку?",
            "", "   ", nil, "kontejner kod pekare", "12345", "1234567"
          ].freeze

          def test_retest_presentation_modifiers_and_script_requests_do_not_hide_new_tasks
            ["Kratko, bez obećanja o neprovjerenim trotoarima.", "Kratko i jasno odvoji bodove od glasa.",
             "Молим ћирилицом", "Napiši latinicom"].each do |text|
              assert TextPredicates.presentation_request?(Text.fold(text)), text
            end
            ["Kratko, kako obrisati nalog?", "Kratko, prijavi rupu na putu"].each do |text|
              refute TextPredicates.presentation_request?(Text.fold(text)), text
            end
            assert_equal "sr", TextPredicates.presentation_locale("Napiši latinicom")
            assert_equal "sr-Cyrl", TextPredicates.presentation_locale("Molim ćirilicom")
            assert TextPredicates.cancel_first_clause?(Text.fold("Одустајем од пута"))
          end

          def test_credential_boundary_keeps_the_state_store_verdicts
            SECRETS.each do |text|
              assert TextPredicates.credential?(text), text.inspect
              assert StateStore.sensitive_text?(text), text.inspect
            end
            ORDINARY.each do |text|
              refute TextPredicates.credential?(text), text.inspect
              refute StateStore.sensitive_text?(text), text.inspect
            end
          end

          def test_cancel_vocabulary_matches_folded_whole_utterances_and_first_clauses
            %w(odustani prekini otkazi cancel stop).each { |word| assert TextPredicates.cancel_command?(word) }
            refute TextPredicates.cancel_command?("odustani od prijave")
            refute TextPredicates.cancel_command?("ne odustajem")
            assert TextPredicates.cancel_first_clause?("odustajem")
            assert TextPredicates.cancel_first_clause?(Text.fold("Odustani od prijave"))
            assert TextPredicates.cancel_first_clause?("cancel the report")
            refute TextPredicates.cancel_first_clause?("odustani od prijave i kazi mi kad je odvoz")
            refute TextPredicates.cancel_first_clause?("stop me")
          end

          def test_repair_phrases_are_whole_utterances_in_one_of_two_languages
            assert TextPredicates.local_repair_phrase?(Text.fold("Pogrešno si me razumjela"))
            assert TextPredicates.local_repair_phrase?("ne nisam rekla da saljes")
            refute TextPredicates.local_repair_phrase?("pogresno si me razumjela hocu drugu adresu")
            assert TextPredicates.english_repair_phrase?(Text.fold("That's not what I meant"))
            assert TextPredicates.english_repair_phrase?("you misunderstood me")
            refute TextPredicates.english_repair_phrase?("pogresno si me razumjela")
            refute TextPredicates.local_repair_phrase?("you misunderstood me")
          end

          def test_board_context_and_qualified_area_shapes
            assert TextPredicates.board_context?(Text.fold("Šta ima na tabli komšiluka?"))
            assert TextPredicates.board_context?("koliko clanova ima")
            refute TextPredicates.board_context?("sta se desava u mz ljeljenca")
            assert TextPredicates.qualified_area?("mz ljeljenca")
            assert TextPredicates.qualified_area?("komsiluk centar 2")
            refute TextPredicates.qualified_area?("mz ljeljenca i dvorovi")
            refute TextPredicates.qualified_area?("mz ljeljenca sutra")
            refute TextPredicates.qualified_area?("ljeljenca")
            refute TextPredicates.qualified_area?("mz ")
            refute TextPredicates.qualified_area?("mz #{"a" * 101}")
          end

          def test_original_constant_names_alias_the_shared_module
            assert_same TextPredicates::CANCEL_COMMANDS, Coordinator::CANCEL_COMMANDS
            assert_same TextPredicates::CANCEL_FIRST_CLAUSE, Coordinator::CANCEL_FIRST_CLAUSE
            assert_same TextPredicates::LOCAL_REPAIR_PHRASES, Coordinator::LOCAL_REPAIR_PHRASES
            assert_same TextPredicates::ENGLISH_REPAIR_PHRASES, Coordinator::ENGLISH_REPAIR_PHRASES
            assert_same TextPredicates::BOARD_CONTEXT, PublicActivityContinuation::PRIVATE_CONTEXT
            assert_same TextPredicates::QUALIFIED_AREA, PublicActivityContinuation::QUALIFIED_AREA
            assert_same TextPredicates::AREA_EXTRA_CLAUSE, PublicActivityContinuation::EXTRA_CLAUSE
            # Procedures::Komsiluk keeps its own copy (out of this package's scope); it must not drift.
            assert_equal TextPredicates::BOARD_CONTEXT, Procedures::Komsiluk::BOARD
            assert TextPredicates::CREDENTIAL_PATTERNS.frozen?
            assert_equal 7, TextPredicates::CREDENTIAL_PATTERNS.size
          end
        end
      end
    end
  end
end
