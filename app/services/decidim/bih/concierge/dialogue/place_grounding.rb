# frozen_string_literal: true

require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Is a place the model handed us actually a place the CITIZEN named?
        #
        # The model fills `area_query` / `street` / `address` from free text, and
        # it silently "corrects" what it cannot read. On 14.09.2026 a citizen
        # wrote "pa u bijelini brate, dsnica" (a mistyped Dašnica) and the model
        # returned "Bijelina, Dvorovi" — a DIFFERENT settlement. The read then
        # answered with Dvorovi's collection days, confidently, for a place
        # nobody had mentioned. A wrong bin day is worse than a shrug: the
        # citizen acts on it.
        #
        # THE THRESHOLD (deliberate; the three outcomes are not interchangeable):
        #
        #   * CONFIDENT — every identifying token of the model's value is
        #     witnessed by a word the citizen actually wrote (this turn, or in
        #     the place slots the conversation already holds). "Bijelina" is
        #     witnessed by "bijelini", "Janja" by "Janji", "Dašnica" by the
        #     typo "dsnica". The value is used; the area matcher then decides
        #     whether it is one place, several, or none of ours.
        #
        #   * MANGLED, SO ASK — the value is PART the citizen's words and part
        #     words they never wrote ("Bijelina, Dvorovi" out of "pa u bijelini
        #     brate, dsnica"). That is the signature of a model that read what
        #     it could and filled in the rest, and we cannot tell which half is
        #     the place. The slot is refused whole — not trimmed — so the
        #     procedure asks its own place question. Refusing is NOT "we hold no
        #     verified record": nothing was read.
        #
        #   * LEFT ALONE — a value with none of the citizen's words in it is a
        #     paraphrase from somewhere else in the conversation (a retained
        #     place, a closed choice, the profile). The dialogue has always
        #     treated the model's entities as authoritative there, and tightening
        #     that is a different change with a different blast radius. It is
        #     deliberately out of scope here.
        #
        # Witnessing tolerates what Serbian actually does to a place name and
        # nothing more: case endings (a shared stem) and a single-character
        # typo. It deliberately does NOT tolerate "shares four letters", which
        # is how "dvorište" would have vouched for "Dvorovi".
        module PlaceGrounding
          # Slots whose value names a place. `area_slug` is excluded on purpose:
          # it is a canonical identifier, already required to appear literally
          # in the text by ProcedureRunner#canonical_candidates_to_citizen_queries.
          # `stop` and `route` are excluded too — a timetable identifier is a
          # different vocabulary and is validated by the timetable, not by words.
          SLOTS = %w(area_query street address).freeze

          # Words that qualify a place without naming one. The model adds them
          # freely ("Ulica Račanska" for "Račanska"), and requiring the citizen
          # to have written them would refuse perfectly good slots.
          QUALIFIERS = %w(
            ulica ulice ulici ulicu ulicom ul
            naselje naselja naselju naseljem
            mjesna mjesne mjesnoj mesna mesne mesnoj zajednica zajednice zajednici mz
            komsiluk komsiluka komsiluku
            grad grada gradu selo sela selu
            broj broja br bb kod prijedlog
          ).freeze

          # Tokens shorter than this carry no place identity (house numbers,
          # "u", "na", initials), so they are never required to be witnessed.
          MIN_IDENTIFYING_LENGTH = 3
          # A shared stem must be at least this long before it counts, so two
          # unrelated short words cannot vouch for each other.
          MIN_STEM = 4
          # How much of the SHORTER token a case ending may eat. Serbian
          # inflection changes one or two trailing characters ("Janja"/"Janji",
          # "Centar"/"Centru"); three would let "Dvorovi" ride on "dvorište".
          MAX_ENDING = 2
          # Below this length a single edited character is most of the word, so
          # the typo tolerance is not offered.
          MIN_TYPO_LENGTH = 5

          module_function

          # True when the value is a QUOTATION the citizen's words cannot
          # support: some of its place words are theirs and some are not.
          # +sources+ are the strings they are allowed to have said it with —
          # this turn's text, plus whatever place slots the conversation already
          # holds (so "mjesna zajednica", answering "komšiluk Janja ili MZ
          # Janja?", still carries Janja).
          def mangled?(value, *sources)
            needles = identifying_tokens(value)
            return false if needles.size < 2

            witnesses = sources.flat_map { |source| tokens(source) }
            grounded, ungrounded = needles.partition do |needle|
              witnesses.any? { |witness| witnessed?(needle, witness) }
            end
            grounded.any? && ungrounded.any?
          end

          def identifying_tokens(value)
            tokens(value).reject { |token| QUALIFIERS.include?(token) || token.length < MIN_IDENTIFYING_LENGTH }
          end

          def tokens(value)
            Text.fold(value.to_s).split(/[^a-z0-9]+/).reject(&:empty?)
          end

          def witnessed?(needle, witness)
            return true if needle == witness

            shorter = [needle.length, witness.length].min
            stem = common_prefix_length(needle, witness)
            # A shared stem vouches for a case ending, never for a coincidence:
            # it must reach MIN_STEM (or the whole of a three-letter word) and
            # leave at most MAX_ENDING characters of the shorter word unmatched.
            return true if stem >= [MIN_STEM, shorter].min && stem >= shorter - MAX_ENDING

            shorter >= MIN_TYPO_LENGTH && one_edit_apart?(needle, witness)
          end

          def common_prefix_length(left, right)
            limit = [left.length, right.length].min
            index = 0
            index += 1 while index < limit && left[index] == right[index]
            index
          end

          # Levenshtein distance of at most one, decided without building a
          # matrix: one substitution, or one insertion/deletion.
          def one_edit_apart?(left, right)
            return false if (left.length - right.length).abs > 1
            return substitution?(left, right) if left.length == right.length

            longer, shorter = left.length > right.length ? [left, right] : [right, left]
            insertion?(longer, shorter)
          end

          def substitution?(left, right)
            differences = 0
            left.each_char.with_index do |char, index|
              next if char == right[index]

              differences += 1
              return false if differences > 1
            end
            true
          end

          def insertion?(longer, shorter)
            offset = 0
            shorter.each_char.with_index do |char, index|
              next if char == longer[index + offset]

              offset += 1
              return false if offset > 1 || char != longer[index + offset]
            end
            true
          end
        end
      end
    end
  end
end
