# frozen_string_literal: true

require "decidim/bih/transliterator"

module Decidim
  module Bih
    # Script- and accent-insensitive text folding for keyword/lookup matching.
    #
    # The same "fold for diacritic/script-insensitive matching" step was
    # reimplemented across the concierge Responder and every City content
    # service (Budget, GazetteIndex, WasteSchedule, ServiceDirectory). This is
    # the single canonical implementation they now all share.
    #
    # #fold turns any Serbian text (Latin or Cyrillic, accented or not) into a
    # lowercase ASCII Latin key so that "Дворови", "dvorovi", "DVOROVI" and
    # "Đorđe"/"djordje" all compare equal:
    #
    #   1. Unicode-normalize (NFC) so a decomposed "č" folds like a composed one.
    #   2. Downcase.
    #   3. Transliterate Cyrillic -> Latin via Decidim::Bih::Transliterator
    #      (Latin passes through unchanged).
    #   4. Fold the remaining Serbian Latin diacritics to their ASCII base
    #      (č/ć -> c, š -> s, ž -> z, đ -> dj).
    #   5. Replace every other non-alphanumeric character with a space, then
    #      collapse runs of whitespace and strip the ends.
    #
    # The result keeps single spaces between words (so "centar za socijalni rad"
    # stays multi-word for substring matching) but drops all other punctuation,
    # which is exactly what both the substring lookups (Budget#amount_for,
    # WasteSchedule#collection_days_for) and the tokenizers
    # (split(/[^a-z0-9]+/)) want.
    module Text
      # Serbian Latin diacritic -> ASCII base. "đ"/"Đ" expand to the digraph
      # "dj"; the rest are 1:1. Applied AFTER downcase, so only lowercase keys.
      DIACRITICS = {
        "č" => "c", "ć" => "c", "đ" => "dj", "š" => "s", "ž" => "z"
      }.freeze

      module_function

      # Fold +text+ to a lowercase ASCII Latin matching key (see the module
      # docstring for the exact pipeline). nil/blank input folds to "".
      def fold(text)
        latin = Decidim::Bih::Transliterator.to_latin(text.to_s.unicode_normalize(:nfc).downcase)
        DIACRITICS.each { |from, to| latin = latin.gsub(from, to) }
        latin.gsub(/[^a-z0-9 ]/, " ").gsub(/\s+/, " ").strip
      end
    end
  end
end
