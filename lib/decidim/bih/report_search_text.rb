# frozen_string_literal: true

require "decidim/bih/transliterator"

module Decidim
  module Bih
    # The single normalisation funnel for report full-text search.
    #
    # Both sides of the search pass through #normalize — the text written into
    # `decidim_bih_reports.search_text` and the operator's typed query — so a
    # report filed in Cyrillic is found by a Latin query and the other way
    # round, and "prljavština" is found by typing "prljavstina".
    #
    # Two steps, in this order:
    #   1. Cyrillic -> Latin (Transliterator#to_latin; Latin passes through)
    #   2. fold the Serbian Latin diacritics away (š->s, č/ć->c, ž->z, đ->dj)
    #
    # PostgreSQL has no Serbian/Bosnian stemmer, so the tsvector is built with
    # the 'simple' configuration (no stemming) and inflection is handled by
    # prefix matching in #tsquery instead.
    module ReportSearchText
      # Applied AFTER to_latin, so only Latin diacritics need entries. "đ"
      # becomes the two-letter "dj" — the spelling citizens actually type when
      # they have no diacritics on the keyboard.
      DIACRITIC_FOLDING = {
        "š" => "s", "č" => "c", "ć" => "c", "ž" => "z", "đ" => "dj"
      }.freeze

      DIACRITICS = Regexp.union(DIACRITIC_FOLDING.keys).freeze

      # Everything that is not a letter or a digit becomes a token boundary.
      # This is what keeps a reference searchable: PostgreSQL's 'simple' parser
      # reads "br-2026-0061" as 'br' '-2026' '-0061' (hyphen included), so a
      # "2026" query would never match. Splitting on punctuation here — on both
      # the indexed text and the query — sidesteps that entirely, and as a
      # side effect no tsquery metacharacter can survive into the query.
      SEPARATORS = /[^[:alnum:]]+/

      # A one-character token matches almost every report, so it narrows
      # nothing while costing a full index scan.
      MIN_TOKEN_LENGTH = 2

      # An operator who pastes a whole paragraph into the box gets the first
      # few words, not an unbounded conjunction.
      MAX_QUERY_TOKENS = 10

      module_function

      # Fold +string+ into the script- and diacritic-free lowercase form the
      # index and the query are both compared in. Returns "" for nil/non-String.
      def normalize(string)
        return "" unless string.is_a?(String)

        Transliterator.to_latin(string)
                      .downcase
                      .gsub(DIACRITICS) { |char| DIACRITIC_FOLDING[char] }
                      .gsub(SEPARATORS, " ")
                      .strip
      end

      # Build the to_tsquery('simple', ...) argument for what the operator
      # typed, or nil when nothing searchable is left. Tokens are ANDed and
      # every one carries the ":*" prefix marker (see the class comment).
      #
      # Safe to interpolate only in the sense that normalisation has already
      # removed every tsquery metacharacter — it is still passed as a bound
      # parameter by the caller, never inlined into SQL.
      def tsquery(string)
        tokens = normalize(string)
                 .split
                 .reject { |token| token.length < MIN_TOKEN_LENGTH }
                 .first(MAX_QUERY_TOKENS)

        return nil if tokens.empty?

        tokens.map { |token| "#{token}:*" }.join(" & ")
      end
    end
  end
end
