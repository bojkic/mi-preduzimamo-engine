# frozen_string_literal: true

module Decidim
  module Bih
    module City
      # Shared, byte-identical text-matching primitives for the City content
      # services (Budget, GazetteIndex, ServiceDirectory, WasteSchedule).
      #
      # These four services are parallel "fold -> tokenize -> ranked lookup"
      # engines. The folding step was already unified in Decidim::Bih::Text.fold;
      # this module unifies the next two genuinely-identical steps so they live
      # once:
      #
      #   * #normalize — fold to a lowercase ASCII Latin matching key (script- and
      #     diacritic-insensitive) via the shared Decidim::Bih::Text.fold. Used by
      #     ALL four services (the substring lookups in Budget#amount_for and
      #     WasteSchedule#collection_days_for, and the tokenizers below).
      #   * #tokenize — split a normalized string into word tokens (length >= 2).
      #     Used IDENTICALLY by GazetteIndex and ServiceDirectory. Budget and
      #     WasteSchedule match by substring rather than tokens and so only use
      #     #normalize.
      #
      # What is DELIBERATELY NOT here: the per-service relevance #score. Gazette
      # and ServiceDirectory weight hits differently (Gazette uses 3/2/1 with a
      # shared-stem tier for Serbian declensions; ServiceDirectory uses 2/1 with
      # no stem tier), and Budget/WasteSchedule do not score at all. Unifying
      # those would change ranked results, so each service keeps its own #score.
      #
      # Mixed in as PRIVATE instance methods (extend ActiveSupport::Concern is not
      # needed — these are plain helpers), so a service calls `normalize(...)` /
      # `tokenize(...)` exactly as it did before the extraction.
      module Matching
        private

        # Folds a value to a lowercase ASCII Latin matching key (Cyrillic ->
        # Latin -> de-accented) so matching ignores script and diacritics.
        # nil/blank folds to "".
        def normalize(value)
          Decidim::Bih::Text.fold(value)
        end

        # Splits a string into normalized word tokens (length >= 2). The split on
        # non-alphanumerics is transparent over the fold's punctuation handling.
        def tokenize(text)
          normalize(text).split(/[^a-z0-9]+/).reject { |token| token.length < 2 }
        end
      end
    end
  end
end
