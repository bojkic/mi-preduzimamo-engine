# frozen_string_literal: true

module Decidim
  module Bih
    # Deterministic, lossless Serbian Latin -> Cyrillic transliteration.
    #
    # Used to generate the `sr-Cyrl` locale from the maintained `sr` (Latin)
    # source, so Serbian only ever has to be translated once.
    #
    # Interpolation placeholders (%{name}, %<n>s), HTML tags (<a href="...">)
    # and Liquid-style tags ({{ var }}) are preserved verbatim — only the
    # human-readable Latin text between them is transliterated.
    module Transliterator
      # Digraphs MUST come before single letters; Regexp.union below is built
      # longest-key-first so they take precedence.
      MAP = {
        "DŽ" => "Џ", "Dž" => "Џ", "dž" => "џ",
        "LJ" => "Љ", "Lj" => "Љ", "lj" => "љ",
        "NJ" => "Њ", "Nj" => "Њ", "nj" => "њ",
        "A" => "А", "B" => "Б", "C" => "Ц", "Č" => "Ч", "Ć" => "Ћ",
        "D" => "Д", "Đ" => "Ђ", "E" => "Е", "F" => "Ф", "G" => "Г",
        "H" => "Х", "I" => "И", "J" => "Ј", "K" => "К", "L" => "Л",
        "M" => "М", "N" => "Н", "O" => "О", "P" => "П", "R" => "Р",
        "S" => "С", "Š" => "Ш", "T" => "Т", "U" => "У", "V" => "В",
        "Z" => "З", "Ž" => "Ж",
        "a" => "а", "b" => "б", "c" => "ц", "č" => "ч", "ć" => "ћ",
        "d" => "д", "đ" => "ђ", "e" => "е", "f" => "ф", "g" => "г",
        "h" => "х", "i" => "и", "j" => "ј", "k" => "к", "l" => "л",
        "m" => "м", "n" => "н", "o" => "о", "p" => "п", "r" => "р",
        "s" => "с", "š" => "ш", "t" => "т", "u" => "у", "v" => "в",
        "z" => "з", "ž" => "ж"
      }.freeze

      LETTERS = Regexp.union(MAP.keys.sort_by { |k| -k.length }).freeze

      # Inverse of MAP (Cyrillic -> Latin). Because several Latin forms map to the
      # same Cyrillic codepoint (e.g. "DŽ"/"Dž"/"dž" -> "Џ"/"џ"), Hash#invert keeps
      # only the LAST Latin form per Cyrillic letter, which is the canonical one:
      # the title-case digraph "Dž"/"Lj"/"Nj" for the uppercase Cyrillic letters
      # and the lowercase "dž"/"lj"/"nj" for the lowercase ones. #to_latin fixes the
      # digraph casing in all-caps context (ЊЕГОШ -> NJEGOŠ, not "NjEGOŠ").
      CYRILLIC_TO_LATIN = MAP.invert.freeze

      # Uppercase Cyrillic digraph letters whose Latin form is a two-character
      # title-case digraph ("Џ" -> "Dž"). In an all-caps run the trailing letter
      # must be uppercased too ("DŽ"); #to_latin decides this from context.
      UPPERCASE_DIGRAPHS = %w(Џ Љ Њ).freeze

      # Every Cyrillic letter we recognise (used to detect uppercase context for
      # digraph casing: a digraph is fully uppercased only when adjacent to
      # another uppercase Cyrillic letter, i.e. inside an all-caps word).
      UPPERCASE_CYRILLIC = CYRILLIC_TO_LATIN.keys.select do |char|
        latin = CYRILLIC_TO_LATIN[char]
        latin == latin.upcase && latin != latin.downcase
      end.freeze

      # Latin brand/technical tokens that must stay Latin in Cyrillic output —
      # transliterating them produces nonsense ("Одоо", "Инфобип", "Вибер цхат",
      # "wеб образац"), or, for URLs/env vars/API names, an unusable value an
      # operator can't copy. The lowercase "web"/"chat" loanwords are kept Latin
      # too (e.g. "web obrazac" -> "web образац", "Viber chat" -> "Вибер chat"),
      # which is the maintainable outcome — it replaces earlier hand-edits that
      # masked the phonetic nonsense and would silently revert on regeneration.
      # Longest-first so multi-word tokens win; the join in PRESERVE keeps order.
      PRESERVED_WORDS = [
        "https://aiplatform.googleapis.com", "community.example.invalid",
        "GEMINI_BASE_URL", "AI Studio",
        # "WhatsAppa" is the Serbian genitive written solid, as the copy uses
        # it ("kod iz WhatsAppa"); the \b in PRESERVE ends at the brand token,
        # so the declined form needs its own entry or it comes out phonetic.
        "Web chat", "WhatsAppa", "WhatsApp", "Messenger", "webhook",
        "Infobip", "Gemini", "Vertex", "Odoo", "WebP", "API",
        # Funders named by the CSI grant's visibility guidelines (see the host
        # app's docs/operations/FUNDER_VISIBILITY.md): spelling and word order
        # are contractual, so they stay Latin in Cyrillic copy. Longest first
        # happens below; "CSI"/"REGIONAL" are the acronyms the copy uses alone.
        "Regional Community Support", "Community Support Initiative",
        "Community Participation Program", "Community Spark", "CommunityPartner",
        "CommunityTools", "COMMUNITY", "REGIONAL", "CSI",
        "BR", "chat", "web",
        "zanasuzajednicu"
      ].sort_by { |word| -word.length }.freeze

      # Segments that must NOT be transliterated, captured so String#split keeps
      # them: %{...} / %<...>x interpolations, strftime directives (%Y, %-d, %^B),
      # HTML tags, {{ ... }}/{% ... %}, and the PRESERVED_WORDS brand tokens
      # (single capture group — the split logic in #call relies on odd indices
      # being the preserved matches).
      #
      # strftime directives carry an ASCII letter (%d/%m/%Y/%B/%a/%H...) that is
      # also a transliterable Latin letter; without preservation the Cyrillic
      # date/time format strings would become "%д/%м/%Y" and break strftime. The
      # letter NAMES they expand to (%B month, %A day) still localize because
      # they read from this locale's own (transliterated) month_names/day_names.
      # %{...} and %<...>x come first in the alternation so brace/angle
      # interpolations win over the bare-directive branch.
      # A URL or e-mail address is a machine token, not prose: transliterating
      # one produces something a citizen cannot click or type
      # ("хттпс://www.комуналацбн.цом/"). PRESERVED_WORDS lists two URLs by
      # hand, which only ever protected those two; this matches any of them.
      # It comes first so a URL wins over the brand-token branch inside it.
      URL_OR_EMAIL = "https?://[^\\s<>\"']+|www\\.[^\\s<>\"']+|\\b[\\w.+-]+@[\\w-]+\\.[\\w.-]+"

      PRESERVE = Regexp.new(
        "(#{URL_OR_EMAIL}" \
        "|%\\{[^}]*\\}|%<[^>]*>[a-zA-Z]?|%[-_^0-9]*[a-zA-Z]|<[^>]+>" \
        "|\\{\\{[^}]*\\}\\}|\\{%[^%]*%\\}" \
        "|\\b(?:#{PRESERVED_WORDS.map { |word| Regexp.escape(word) }.join("|")})\\b)"
      )

      module_function

      # Transliterate a single string, preserving placeholders and markup.
      def call(string)
        return string unless string.is_a?(String)

        string.split(PRESERVE).each_with_index.map do |segment, index|
          # Odd indices are the captured PRESERVE matches — keep them as-is.
          index.odd? ? segment : segment.gsub(LETTERS, MAP)
        end.join
      end

      # Fold Cyrillic text back to Latin (the inverse of #call), so a Cyrillic
      # value can be displayed under a Latin locale and script-insensitive
      # matching can compare a Cyrillic message against Latin keyword lists.
      # Latin input passes through unchanged. Diacritic Latin letters
      # (š/č/ć/ž/đ) are produced as-is for the caller to fold further if needed.
      #
      # Digraph casing is context-aware: "Џ"/"Љ"/"Њ" become the title-case
      # "Dž"/"Lj"/"Nj" normally, but the trailing letter is uppercased inside an
      # all-caps run so "ЊЕГОШ" -> "NJEGOŠ" (not "NjEGOŠ") and "Џ" before a
      # lowercase letter stays "Dž". This keeps Latin->Cyrillic->Latin lossless.
      def to_latin(string)
        return string unless string.is_a?(String)

        chars = string.chars
        chars.each_with_index.map do |char, index|
          latin = CYRILLIC_TO_LATIN[char]
          next char unless latin

          if UPPERCASE_DIGRAPHS.include?(char) && all_caps_context?(chars, index)
            latin.upcase
          else
            latin
          end
        end.join
      end

      # Render +string+ in the script of +locale+ without mutating its meaning:
      # Latin for Latin-script locales (sr/bs/hr/en and anything not sr-Cyrl),
      # Cyrillic for "sr-Cyrl". The source script is detected, so a Cyrillic-
      # stored value displays Latin under sr/bs/hr and a Latin-stored value
      # displays Cyrillic under sr-Cyrl. Idempotent when already in the target
      # script. Non-String input is returned unchanged.
      def localize(string, locale:)
        return string unless string.is_a?(String)

        if locale.to_s == "sr-Cyrl"
          call(string)
        else
          to_latin(string)
        end
      end

      # True when the Cyrillic letter at +index+ sits in an all-caps run: the
      # nearest alphabetic Cyrillic neighbour (previous, else next) is uppercase.
      # A lone uppercase digraph (no Cyrillic neighbour, e.g. "Њ") is treated as
      # title-case, matching how a single capitalised word transliterates.
      def all_caps_context?(chars, index)
        neighbour = nearest_cyrillic(chars, index - 1, -1) ||
                    nearest_cyrillic(chars, index + 1, 1)
        return false unless neighbour

        UPPERCASE_CYRILLIC.include?(neighbour)
      end

      # Walk +chars+ from +start+ in +step+ direction, returning the first
      # recognised Cyrillic letter, or nil if none before the string end.
      def nearest_cyrillic(chars, start, step)
        index = start
        while index >= 0 && index < chars.length
          char = chars[index]
          return char if CYRILLIC_TO_LATIN.has_key?(char)

          index += step
        end
        nil
      end

      # Recursively transliterate every String value in a nested Hash/Array
      # structure (keys are left untouched — they are i18n keys, not content).
      def deep(node)
        case node
        when String then call(node)
        when Array then node.map { |item| deep(item) }
        when Hash then node.transform_values { |value| deep(value) }
        else node
        end
      end
    end
  end
end
