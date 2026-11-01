# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/turn_budget"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/understand"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # The lexicon is prompt content plus deterministic fold hints. The
        # model still classifies; these tests prove the local words reach it
        # and that the hints are bounded advisory data, never a decision.
        class UnderstandLexiconTest < Minitest::Test
          VALID_RESPONSE = {
            "action" => "report_problem", "topic" => "roads", "entities" => {}, "operation" => "start",
            "needs_clarification" => false, "secondary" => nil, "locale" => "sr"
          }.freeze

          class FakeClient
            attr_reader :calls

            def initialize
              @calls = []
            end

            def configured? = true

            def generate_content(**arguments)
              calls << arguments
              VALID_RESPONSE
            end
          end

          BASE_CONFIGURATION = {
            "version" => 1, "max_understanding_seconds" => 6.0, "max_history_turns" => 6,
            "max_history_text_length" => 1000, "system_instruction" => "Classify only."
          }.freeze

          # phrase, hinted topics (sorted), the appendix term that covers it
          LOCAL_PHRASINGS = [
            ["Pala bandera u Ledincima", %w(roads), "bandera"],
            ["Bandera ne svijetli već tri dana", %w(roads), "bandera"],
            ["Udario je auto u banderu kod škole", %w(roads), "bandera"],
            ["Пала бандера", %w(roads), "bandera"],
            ["Kaldrma se raspala u Sokolskoj", %w(roads), "kaldrma"],
            ["Kaldrmu treba popraviti", %w(roads), "kaldrma"],
            ["Rupa na putu ispred kuće", %w(report), "rupa"],
            ["Ima rupe po cijeloj ulici", %w(report), "rupa"],
            ["Ogromna udarna rupa na Majevičkoj", %w(report), "udarna rupa"],
            ["Šaht otvoren kod pijace", %w(roads), "šaht"],
            ["Sahta nema poklopac", %w(roads), "šaht"],
            ["Отворен шахт на тротоару", %w(roads), "šaht"],
            ["Neko istovario šut pored puta", %w(bulky_waste), "šut"],
            ["Шут поред пута", %w(bulky_waste), "šut"],
            ["Divlja deponija iza groblja", %w(bulky_waste), "deponija"],
            ["Bacaju šut na deponiju", %w(bulky_waste), "deponija"],
            ["Kanta nije pražnjena sedmicu", %w(waste), "kanta"],
            ["Kad se prazne kante u Dvorovima?", %w(waste), "kanta"],
            ["Kontejner je pun i smrdi", %w(waste), "kontejner"],
            ["Đubre svuda po ulici", %w(waste), "đubre"],
            ["Djubre pored kontejnera", %w(waste), "djubre"],
            ["Ђубре поред контејнера", %w(waste), "đubre"],
            ["Smeće nije odneseno", %w(waste), "smeće"],
            ["Bunar je presušio", %w(water), "bunar"],
            ["Voda curi iz bunara", %w(water), "bunar"],
            ["Бунар пресушио", %w(water), "bunar"],
            ["Šahta za vodu puna vode", %w(roads water), "šahta za vodu"],
            ["Pao dalekovod kod Dvorova", %w(electricity), "dalekovod"],
            ["Далековод пао на пут", %w(electricity), "dalekovod"],
            ["Trafo brekće cijelu noć", %w(electricity), "trafo"],
            ["Bandera struja iskri", %w(electricity roads), "bandera struja"],
            ["Šta ima u našem sokaku?", %w(neighborhood), "sokak"],
            ["U našoj mahali nema rasvjete", %w(neighborhood), "mahala"],
            ["Шта се дешава у махали?", %w(neighborhood), "mahala"],
            ["Naselje Ledinci", %w(neighborhood), "naselje"],
            ["Imamo belaj sa vodom", [], "belaj"],
            ["Велики белај", [], "belaj"]
          ].freeze

          def setup
            @client = FakeClient.new
            @understand = Understand.new(client: @client, wall_clock: -> { Time.utc(2026, 9, 13, 9) })
          end

          def budget = TurnBudget.new(timeout: 10)

          def test_at_least_thirty_local_phrasings_are_covered_by_fold_hints_and_the_appendix
            assert_operator LOCAL_PHRASINGS.size, :>=, 30
            @understand.call(message: "Da li je bilten obavezan?", state: {}, history: [], deadline: budget)
            instruction = @client.calls.fetch(0).fetch(:system_instruction)

            LOCAL_PHRASINGS.each do |phrase, topics, term|
              assert_equal topics, @understand.lexicon_hints(phrase).sort, "hints for #{phrase.inspect}"
              assert_includes instruction, term, "appendix lacks #{term.inspect} for #{phrase.inspect}"
            end
          end

          def test_shipped_appendix_follows_the_base_instruction_within_the_raised_limit
            @understand.call(message: "Da li je bilten obavezan?", state: {}, history: [], deadline: budget)

            configuration = YAML.safe_load_file(Understand::DEFAULT_CONFIGURATION_PATH, aliases: false)
            instruction = @client.calls.fetch(0).fetch(:system_instruction)
            base = configuration.fetch("system_instruction")
            assert instruction.start_with?(base.rstrip), "the base instruction must come first, unchanged"
            appendix = instruction.delete_prefix(base.rstrip)
            assert appendix.start_with?("\n\nLocal words"), appendix[0, 40].inspect
            assert_includes appendix, "bandera = street light pole → roads"
            assert_includes appendix, "lexicon_topics"
            refute_includes appendix, "→ unknown"
            assert_operator instruction.length, :<=, Understand::MAX_INSTRUCTION_LENGTH
            assert_equal 10_000, Understand::MAX_INSTRUCTION_LENGTH
            configuration.fetch("lexicon").each do |entry|
              assert_includes appendix, entry.fetch("term")
              assert_includes appendix, entry.fetch("meaning")
              assert_includes Contracts::TOPICS, entry.fetch("topic")
            end
          end

          def test_hints_reach_the_projection_only_when_a_local_word_is_present
            @understand.call(message: "Pala bandera kod škole", state: {}, history: [], deadline: budget)
            @understand.call(message: "Nastavi", state: {}, history: [], deadline: budget)

            with_hint, without_hint = @client.calls.map { |call| JSON.parse(call.fetch(:contents).last.dig(:parts, 0, :text)) }
            assert_equal %w(roads), with_hint.dig("conversation", "lexicon_topics")
            refute with_hint["conversation"].has_key?("suspended_task")
            refute without_hint.fetch("conversation").has_key?("lexicon_topics")
            assert_equal "report_problem", VALID_RESPONSE.fetch("action") # the fake decides; hints never do
          end

          def test_hints_are_unique_frozen_topics_in_lexicon_order_and_never_unknown
            hints = @understand.lexicon_hints("Šut i đubre kod kontejnera, pravi belaj, i još šuta")

            assert_equal %w(bulky_waste waste), hints
            assert hints.frozen?
            assert_empty @understand.lexicon_hints("")
            assert_empty @understand.lexicon_hints(nil)
            assert_empty @understand.lexicon_hints(12_345)
            assert_empty @understand.lexicon_hints("sutra dolazi autobus u kanton") # "sut" and "kant" prefixes are not words
          end

          def test_configuration_without_a_lexicon_still_loads_and_sends_the_instruction_unchanged
            understand = Understand.new(client: @client, configuration: BASE_CONFIGURATION)

            understand.call(message: "Pala bandera", state: {}, history: [], deadline: budget)

            assert_equal "Classify only.", @client.calls.fetch(0).fetch(:system_instruction)
            assert_empty understand.lexicon_hints("Pala bandera")
            payload = JSON.parse(@client.calls.fetch(0).fetch(:contents).last.dig(:parts, 0, :text))
            refute payload.fetch("conversation").has_key?("lexicon_topics")
          end

          def test_a_small_custom_lexicon_is_rendered_and_hinted
            configuration = BASE_CONFIGURATION.merge("lexicon" => [{ "term" => "Ćuprija", "meaning" => "bridge", "topic" => "roads" }])
            understand = Understand.new(client: @client, configuration:)

            understand.call(message: "Ćuprija se ruši", state: {}, history: [], deadline: budget)

            instruction = @client.calls.fetch(0).fetch(:system_instruction)
            assert instruction.start_with?("Classify only.\n\nLocal words")
            assert_includes instruction, "Ćuprija = bridge → roads"
            assert_equal %w(roads), understand.lexicon_hints("cuprija")
            assert_equal %w(roads), understand.lexicon_hints("ЋУПРИЈА")
          end

          def test_a_malformed_lexicon_raises_invalid
            entry = { "term" => "bandera", "meaning" => "street light pole", "topic" => "roads" }
            malformed = {
              "not a list" => "bandera",
              "nil" => nil,
              "too many entries" => Array.new(41) { |index| entry.merge("term" => "rijec#{index}") },
              "missing meaning" => [entry.except("meaning")],
              "unknown topic" => [entry.merge("topic" => "streetlights")],
              "extra key" => [entry.merge("weight" => 3)],
              "long term" => [entry.merge("term" => "b" * 41)],
              "long meaning" => [entry.merge("meaning" => "m" * 81)],
              "blank term" => [entry.merge("term" => " ")],
              "punctuation term" => [entry.merge("term" => "!!!")],
              "control character" => [entry.merge("meaning" => "pole ")],
              "duplicate folded term" => [entry, entry.merge("term" => "Бандера", "topic" => "electricity")]
            }

            malformed.each do |label, lexicon|
              assert_raises(Contracts::Invalid, label) do
                Understand.new(client: @client, configuration: BASE_CONFIGURATION.merge("lexicon" => lexicon))
              end
            end
          end

          # R3 replay, 14.09.2026: "Imam fotografiju rupe. Šta da radim sa
          # njom?" was answered with 1.553 characters of Cyrillic motorway
          # roadworks bulletins. "rupa" hinted the "roads" topic, and "roads"
          # is the REGIONAL road-conditions feed (AMS RS "stanje na putevima"),
          # not the street outside the citizen's house. A pothole is something
          # one citizen REPORTS, so that is what it hints now. The hint is
          # advisory either way - the model still classifies - but a hint that
          # aims at a highway bulletin is a hint aimed at the wrong answer.
          def test_a_pothole_hints_the_report_topic_and_not_the_regional_road_feed
            [
              "Imam fotografiju rupe. Šta da radim sa njom?",
              "Imamo ogromnu rupu na putu, sta da radim?",
              "Ogromna udarna rupa na Majevičkoj",
              "Рупа на путу"
            ].each do |phrase|
              assert_equal %w(report), @understand.lexicon_hints(phrase), "hints for #{phrase.inspect}"
            end
          end

          # ...and the roads topic stays reachable by the words that really do
          # name a road rather than a defect in one.
          def test_the_roads_topic_is_still_reachable_from_its_own_local_words
            assert_equal %w(roads), @understand.lexicon_hints("Pala bandera u Ledincima")
            assert_equal %w(roads), @understand.lexicon_hints("Kaldrma se raspala u Sokolskoj")
            assert_equal %w(roads), @understand.lexicon_hints("Šaht otvoren kod pijace")
          end

          def test_the_combined_instruction_is_bounded_even_when_each_part_is_within_its_own_limit
            base = BASE_CONFIGURATION.merge("system_instruction" => "x" * 8_000)
            lexicon = Array.new(40) { |index| { "term" => "rijec#{index}".ljust(40, "a"), "meaning" => "m" * 80, "topic" => "roads" } }

            assert_raises(Contracts::Invalid) { Understand.new(client: @client, configuration: base.merge("lexicon" => lexicon)) }
            Understand.new(client: @client, configuration: base) # the base alone is still accepted at its limit
          end
        end
      end
    end
  end
end
