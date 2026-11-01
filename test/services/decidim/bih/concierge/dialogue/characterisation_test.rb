# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../support/decidim/bih/dialogue_characterisation"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Task 0 (seam extraction) must change no behaviour. This locks the
        # whole dialogue turn — routing, pre-model stages, fact rendering and
        # resolution labelling — to a transcript captured before the extraction.
        #
        # The baseline was captured on the pre-extraction tree and is committed
        # next to this test. A diff here is a behaviour change: understand it
        # before regenerating the baseline, and never regenerate it to make a
        # refactor "pass".
        #
        # Regenerate deliberately (after an intended behaviour change) with:
        #   CHARACTERISATION_WRITE=1 bundle exec ruby -Itest \
        #     test/services/decidim/bih/concierge/dialogue/characterisation_test.rb
        class CharacterisationTest < Minitest::Test
          BASELINE = File.expand_path("../../../../../fixtures/dialogue_characterisation_baseline.txt", __dir__)

          def test_every_characterised_reply_is_byte_identical_to_the_baseline
            transcript = Characterisation.run
            if ENV["CHARACTERISATION_WRITE"] == "1"
              File.write(BASELINE, transcript)
              skip "baseline rewritten: #{BASELINE}"
            end

            assert_equal File.read(BASELINE), transcript, "the characterisation transcript changed — see #{BASELINE}"
          end

          def test_the_corpus_covers_the_required_answer_families_and_size
            names = Characterisation::Corpus.cases.map { |example| example.fetch(:name) }
            prompts = Characterisation::Corpus.cases.sum { |example| example.fetch(:steps).size }

            assert_equal names.uniq, names, "characterisation case names must be unique"
            assert_operator prompts, :>=, 30, "the plan requires at least 30 characterised prompts"
            %w(emergency civic service registration catalogue control continuity report).each do |family|
              assert names.any? { |name| name.start_with?(family) }, "no characterised case for #{family}"
            end
          end
        end
      end
    end
  end
end
