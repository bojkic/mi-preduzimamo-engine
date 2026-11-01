# frozen_string_literal: true

require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # THE four-way top-level menu, read back.
        #
        # "Želiš li prijaviti gradski problem, pomoć s nalogom, podatke o
        # gradskoj usluzi ili informacije o komšiluku?" invites the citizen to
        # name one of four things, and a citizen who names one is not asking a
        # new question — they are answering. Typed back verbatim on 14.09.2026,
        # "Podaci o gradskoj usluzi" was classified as a WEATHER question and
        # answered with MeteoAlarm; nothing in the menu's own wording selected
        # the lane the menu had just offered.
        #
        # Only the service option lives here. The other three already reach
        # their lane through understanding ("Informacije o komšiluku" returns
        # the neighbourhood clarifier, verified the same day), and pinning a
        # working route would change behaviour for no defect.
        module TopicMenu
          # Deliberately a whole-utterance match on folded text: a sentence that
          # asks something as well ("podaci o gradskoj usluzi vodovod") is a
          # real question and keeps its normal path. /x, so every literal space
          # is spelled [ ] — an unescaped one is dropped silently and the
          # alternative holding it can never match.
          INFORMATION = /(?:podat(?:ke|ak|aka)|podac(?:i|ima)|informacij\w*)/
          SERVICE_CHOICE = /\A(?:(?:zelim|hocu|treba[ ]mi|trebaju[ ]mi|zanima[ ]me|zanimaju[ ]me)\s+)?
                            (?:#{INFORMATION.source}\s+o\s+(?:gradsk(?:oj|im)\s+)?uslu(?:zi|gama|gi)|
                               gradsk(?:a|e|oj|im)\s+uslug(?:a|e|i|ama)|
                               ask\s+about\s+a\s+city\s+service|city\s+service\s+information)\z/x

          module_function

          # +query+ is already folded by the caller (CivicQuestion folds and
          # bounds the length before any route sees it).
          def service_choice?(query) = SERVICE_CHOICE.match?(query.to_s)

          # For callers holding raw citizen text rather than a folded query.
          def service_choice_text?(text) = service_choice?(Decidim::Bih::Text.fold(text.to_s))
        end
      end
    end
  end
end
