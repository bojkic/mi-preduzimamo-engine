# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/text"
require_relative "../../../../../app/services/decidim/bih/city/matching"
require_relative "../../../../../app/services/decidim/bih/city/service_directory"

module Decidim
  module Bih
    module City
      # What it takes for a query to be ABOUT a service, rather than merely to
      # share a character or two with one.
      #
      # The directory ranks by token overlap, and two kinds of overlap were
      # measured electing the wrong service in the 14.09.2026 replay of 648
      # production turns: a bare number, and a single substring hit. Both are
      # guarded here against a small stand-in directory shaped like the two
      # real entries that were mis-selected (the host owns the real data).
      class ServiceDirectoryTest < Minitest::Test
        ENTRIES = [
          { key: :prijava_problema,
            title: "Prijava komunalnog problema (Sistem 48 / Bice rijeseno!)",
            keywords: %w(prijava problem kvar rupa sistem48 sistem-48 48 komunalni),
            answer: "Komunalni problem prijavljujete putem \"Sistem 48\".",
            source_url: "http://example.org/48" },
          { key: :gradjevinske_dozvole_legalizacija,
            title: "Gradjevinske dozvole i legalizacija objekata",
            keywords: %w(gradjevinska dozvola dozvole legalizacija lokacijski uslovi urbanizam),
            answer: "Zahtjeve za gradjevinsku dozvolu vodi Odsjek za gradjevinske dozvole.",
            source_url: "http://example.org/dozvole" },
          { key: :otpad,
            title: "Odvoz otpada",
            keywords: %w(smece kanta kontejner odvoz otpad),
            answer: "Raspored odvoza otpada objavljuje Komunalac.",
            source_url: "http://example.org/otpad" }
        ].freeze

        def setup
          @directory = ServiceDirectory.new(ENTRIES)
        end

        # "48" is a keyword AND a word of the Sistem 48 entry's title, so it
        # scored a clean whole-term hit. "Kad oni stizu: odmah, nakon 24 ili
        # nakon 48 sati?" - a citizen counting hours - was answered with the
        # city's complaint-reporting card on that hit alone.
        def test_a_bare_number_cannot_elect_a_service_on_its_own
          assert_empty keys("Kad oni stižu: odmah, nakon 24 ili nakon 48 sati?")
          assert_empty keys("Čekam 48 sati i ništa")
        end

        # ...and the service is still reachable by a real question about it,
        # where a word names it and the number only confirms it.
        def test_a_number_still_counts_once_a_word_has_named_the_service
          assert_equal [:prijava_problema], keys("Šta je Sistem 48?")
          assert_equal [:prijava_problema], keys("Znači li Sistem 48 da moraju riješiti za 48 sati?")
          assert_equal 4, score(:prijava_problema, "Šta je Sistem 48?")
          assert_equal 2, score(:prijava_problema, "Šta je Sistem?")
        end

        # "uslov" ("Da li je potvrda dolaska uslov za ulaz ili samo molba?" -
        # an invitation question) overlaps "uslovi" from "lokacijski uslovi",
        # and that single fuzzy point was the entire match, so the citizen was
        # answered with the building-permits office.
        def test_a_lone_substring_overlap_cannot_elect_a_service
          assert_empty keys("Da li je potvrda dolaska uslov za ulaz ili samo molba?")
          assert_empty keys("Jesam li ispunio uslov?")
        end

        # ...and a real building-permit question still selects it.
        def test_the_permits_entry_is_still_reachable_by_its_own_words
          assert_equal [:gradjevinske_dozvole_legalizacija], keys("Koji su lokacijski uslovi za gradnju?")
          assert_equal [:gradjevinske_dozvole_legalizacija], keys("Gdje se vadi građevinska dozvola?")
          assert_equal [:gradjevinske_dozvole_legalizacija], keys("Legalizacija objekta bez dozvole")
        end

        # The guard is about what may ELECT an entry, not about how a named one
        # is ranked: a fuzzy hit still adds its point once a word has named it.
        def test_ranking_is_unchanged_for_an_entry_a_word_has_named
          assert_equal [:otpad], keys("Kad se prazni kanta za smeće?")
          assert_equal 4, score(:otpad, "Kad se prazni kanta za smeće?")
          assert_equal 3, score(:otpad, "Kad se prazni kanta za otpadom?")
          assert_equal 0, score(:otpad, "Šta je sa otpadom?")
        end

        private

        def keys(query) = @directory.search(query).map { |entry| entry[:key] }

        def score(key, query)
          entry = @directory.find(key)
          @directory.send(:score, entry, @directory.send(:search_tokens, query))
        end
      end
    end
  end
end
