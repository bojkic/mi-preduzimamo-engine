# frozen_string_literal: true

require "test_helper"
require "decidim/bih/report_search_text"

module Decidim
  module Bih
    # The normalisation lijevak both the stored index and the operator's query
    # pass through. Its whole job is to make "Боста", "Bosta" and "bosta" one
    # token, so a search finds a report whatever script it was filed in.
    class ReportSearchTextTest < Minitest::Test
      def test_folds_cyrillic_to_latin
        assert_equal "prostor bivseg bosta", ReportSearchText.normalize("Простор бившег Боста")
      end

      def test_folds_diacritics_so_prljavstina_matches_prljavstina
        assert_equal "prljavstina", ReportSearchText.normalize("prljavština")
      end

      def test_folds_dj_digraph_to_dj
        assert_equal "djubre djaci", ReportSearchText.normalize("Đubre đaci")
      end

      def test_folds_cyrillic_and_latin_spelling_of_the_same_word_identically
        assert_equal ReportSearchText.normalize("Боста"), ReportSearchText.normalize("Bosta")
      end

      # PostgreSQL's 'simple' parser tokenises "br-2026-0061" as
      # 'br' '-2026' '-0061' — the numeric parts keep the hyphen, so a "2026"
      # query never matches. Punctuation is therefore split into separate
      # tokens on BOTH sides of the search rather than carried into the index.
      def test_splits_a_report_reference_into_searchable_tokens
        assert_equal "br 2026 0061", ReportSearchText.normalize("BR-2026-0061")
      end

      def test_collapses_whitespace_and_newlines
        assert_equal "dva reda", ReportSearchText.normalize("Dva\r\n  reda")
      end

      def test_returns_empty_string_for_nil
        assert_equal "", ReportSearchText.normalize(nil)
      end

      # #tsquery turns what the operator typed into a to_tsquery('simple', ...)
      # argument. Every token gets a ":*" prefix marker because 'simple' does no
      # stemming: without it "signaliz" would not find "signalizacija", and
      # Serbian inflects heavily enough that exact-token search is useless.
      def test_builds_a_prefix_query_for_a_single_word
        assert_equal "bost:*", ReportSearchText.tsquery("Bost")
      end

      def test_ands_every_word_of_a_multi_word_query
        assert_equal "izblijedjela:* & signaliz:*", ReportSearchText.tsquery("Izblijedjela signaliz")
      end

      def test_builds_the_same_query_from_cyrillic_and_latin_input
        assert_equal ReportSearchText.tsquery("Боста"), ReportSearchText.tsquery("Bosta")
      end

      def test_splits_a_reference_query_into_anded_tokens
        assert_equal "br:* & 2026:* & 0061:*", ReportSearchText.tsquery("BR-2026-0061")
      end

      def test_drops_single_character_tokens_that_would_match_everything
        assert_equal "bost:*", ReportSearchText.tsquery("u Bost")
      end

      def test_returns_nil_when_nothing_searchable_remains
        assert_nil ReportSearchText.tsquery("  &  ")
      end

      def test_returns_nil_for_a_blank_query
        assert_nil ReportSearchText.tsquery("")
      end

      # An operator pasting a paragraph must not turn into an unbounded query.
      def test_caps_the_number_of_tokens
        query = ReportSearchText.tsquery((1..30).map { |i| "rijec#{i}" }.join(" "))

        assert_equal ReportSearchText::MAX_QUERY_TOKENS, query.split(" & ").length
      end

      # tsquery metacharacters are stripped by normalisation, so a query that
      # tries to inject operators degrades into plain tokens rather than
      # reaching to_tsquery as syntax.
      def test_strips_tsquery_operators_from_the_query
        assert_equal "bost:* & xx:*", ReportSearchText.tsquery("bost & !xx")
      end
    end
  end
end
