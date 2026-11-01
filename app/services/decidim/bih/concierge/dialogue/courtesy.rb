# frozen_string_literal: true

require_relative "../../text"
require_relative "../responder"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Whole-utterance courtesy: a greeting, thanks, a farewell or "what can
        # you do". Matched on the folded text before admission and before the
        # model, so the first seconds of a conversation never wait on a
        # provider. Thanks and farewells are never cancellations; the reply is
        # the phrase-bank line and the active task stays exactly as it was.
        module Courtesy
          KINDS = %w(greeting thanks farewell capabilities closure).freeze
          MAX_LENGTH = 60
          # An optional trailing address ("hvala Milice", "ćao komšinice").
          NAME = '(?:\s+(?:komsinic[ae]|milic[ae]))?'
          # An ordinary closing often acknowledges before it thanks ("Dobro,
          # hvala."). Without these prefixes such a turn reached the model and
          # came back as a cancellation that wiped the citizen's whole task.
          ACKNOWLEDGEMENT = '(?:(?:e|pa|ma|ok|oke|okej|okay|dobro|super|odlicno|u\s+redu|va\s+redu|to\s+je\s+to|sve\s+jasno|jasno|razumijem|razumem)\s+)*'
          # The tail an ordinary closing adds after the thanks itself.
          THANKS_TAIL = '(?:\s+(?:to\s+je\s+sve|dovoljno(?:\s+je)?|sve\s+jasno|jasno|puno|that\s+s\s+all|that\s+is\s+all))?'
          # == The two halves of every courtesy, and why they are separate
          #
          # Each matcher below is composed from a LOCAL half and an ENGLISH
          # half. The union is exactly the pattern that was here before, so
          # what counts as a courtesy is unchanged — but the split lets
          # #locale_hint say which language the citizen wrote in, from the
          # alternative that actually matched. That is a closed vocabulary, not
          # a guess about free text: "hello" is English because it is in the
          # English half, and nothing else is consulted.
          #
          # Before this split an English "hello" was answered with the Serbian
          # greeting card, because the only locale signal available at this
          # point was I18n.locale — the language of the PAGE, which for an
          # English-speaking visitor to a Serbian site is still Serbian.
          #
          # The shared fragments (NAME, ACKNOWLEDGEMENT, the thanks
          # intensifier and tail) stay shared deliberately: "thanks puno" and
          # "hvala very much" are both real, and the core word has already
          # decided the language by the time they are read.
          GREETING_LOCAL = 'zdravo|cao|ciao|pozdrav|hej|ej|halo|dobar\s+dan|dobro\s+jutro|dobro\s+vece|dobar\s+vecer|dobra\s+vecer'
          GREETING_ENGLISH = "hey|hello|hi"
          GREETING_RE = /\A(?:#{GREETING_LOCAL}|#{GREETING_ENGLISH})#{NAME}\z/o
          ENGLISH_GREETING_RE = /\A(?:#{GREETING_ENGLISH})#{NAME}\z/o
          THANKS_INTENSIFIER = '(?:\s+(?:ti|vam|puno|lijepo|lepo|mnogo|najljepse|najlepse|much|very|a\s+lot|so\s+much))*'
          THANKS_LOCAL = "hvala|fala"
          THANKS_ENGLISH = 'thanks|thank\s+you|thx'
          THANKS_RE = /\A#{ACKNOWLEDGEMENT}(?:#{THANKS_LOCAL}|#{THANKS_ENGLISH})#{THANKS_INTENSIFIER}#{THANKS_TAIL}#{NAME}\z/o
          ENGLISH_THANKS_RE = /\A#{ACKNOWLEDGEMENT}(?:#{THANKS_ENGLISH})#{THANKS_INTENSIFIER}#{THANKS_TAIL}#{NAME}\z/o
          # FAREWELL_LOCAL and CAPABILITIES_LOCAL below wrap over several lines
          # and are therefore only safe inside an /x pattern, where the literal
          # newline and indentation are ignored. Every space INSIDE them is
          # written \s+ for the same reason the rest of this file does: in /x,
          # an unescaped literal space is dropped and the alternative spelled
          # with one can never match. ExtendedRegexpSpacesTest holds the
          # composed patterns to that.
          FAREWELL_LOCAL = 'dovidjenja|dovidenja|do\s+vidjenja|cao\s+cao|zbogom|prijatno|vidimo\s+se|
                            pozdrav\s+i\s+hvala|hvala\s+i\s+pozdrav|hvala\s+i\s+dovidjenja|hvala\s+i\s+cao'
          FAREWELL_ENGLISH = 'bye|goodbye|bye\s+bye'
          FAREWELL_RE = /\A(?:#{FAREWELL_LOCAL}|#{FAREWELL_ENGLISH})#{NAME}\z/ox
          ENGLISH_FAREWELL_RE = /\A(?:#{FAREWELL_ENGLISH})#{NAME}\z/ox
          CAPABILITIES_LOCAL = '(?:(?:a|reci\s+mi|kazi\s+mi)\s+)?(?:sta|sto)\s+(?:(?:sve|ti|to)\s+)?(?:znas|mozes|umijes|umes|radis|nudis)
                                 (?:\s+(?:da\s+)?(?:uradis|uraditi|radis|za\s+mene))?|
                               kako\s+radis|kako\s+(?:mi\s+)?(?:(?:mozes|mozete)\s+)?(?:da\s+)?(?:pomoci|pomognes|pomognete)|
                               pomozi\s+mi|treba\s+mi\s+pomoc|(?:koje\s+su\s+)?(?:tvoje\s+)?mogucnosti|cemu\s+sluzis|za\s+sta\s+(?:sve\s+)?sluzis'
          CAPABILITIES_ENGLISH = 'what\s+can\s+you\s+do|what\s+do\s+you\s+do|how\s+can\s+you\s+help(?:\s+me)?'
          CAPABILITIES_RE = /\A(?:#{CAPABILITIES_LOCAL}|#{CAPABILITIES_ENGLISH})#{NAME}\z/ox
          ENGLISH_CAPABILITIES_RE = /\A(?:#{CAPABILITIES_ENGLISH})#{NAME}\z/ox
          # One English matcher per kind, read by #locale_hint after #kind has
          # already decided which kind this is. Keeping the lookup keyed by
          # kind means the hint can never disagree with the courtesy it
          # describes.
          ENGLISH_BY_KIND = {
            "greeting" => ENGLISH_GREETING_RE, "thanks" => ENGLISH_THANKS_RE,
            "farewell" => ENGLISH_FAREWELL_RE, "capabilities" => ENGLISH_CAPABILITIES_RE
          }.freeze

          module_function

          # Returns one of KINDS, or nil for anything that is not a bare
          # courtesy (a question with a greeting in front of it, a command, a
          # long text). Never raises on non-string input.
          def kind(text)
            return unless text.is_a?(String)

            stripped = text.strip
            return unless stripped.length.between?(1, MAX_LENGTH)

            folded = Decidim::Bih::Text.fold(stripped)
            return if folded.empty?
            return "closure" if folded == "ne treba novo objasnjenje niti pitanje"
            return "thanks" if THANKS_RE.match?(folded)
            return "farewell" if FAREWELL_RE.match?(folded)
            return "greeting" if GREETING_RE.match?(folded)
            return "capabilities" if CAPABILITIES_RE.match?(folded) || Responder::HELP_PHRASES.include?(folded)

            nil
          end

          # "en" when the courtesy was written in English, nil for everything
          # else — including a courtesy this module does not recognise at all.
          # It reuses #kind, so the precedence between thanks, farewell,
          # greeting and capabilities is decided in exactly one place, and the
          # hint always describes the courtesy that was actually matched.
          #
          # A nil here is not "this is Serbian": it is "no language was
          # established", and the caller keeps whatever fallback it had.
          def locale_hint(text)
            matched = kind(text)
            pattern = ENGLISH_BY_KIND[matched]
            return unless pattern

            "en" if pattern.match?(Decidim::Bih::Text.fold(text.to_s.strip))
          end
        end
      end
    end
  end
end
